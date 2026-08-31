import Cocoa
import FlutterMacOS
import CoreBluetooth

/// Native CoreBluetooth bridge for QuickShare's Bluetooth transport.
///
/// nearby_connections (used on Android/iOS) has no macOS implementation at
/// all, so this is a from-scratch GATT-based file transfer:
///
///   Sender   = CBPeripheralManager, advertises a custom service and streams
///              the file as notifications once a receiver subscribes and
///              signals it is ready.
///   Receiver = CBCentralManager, scans for that service, connects, and
///              reassembles the file from notifications in arrival order.
///
/// GATT layout (see `ServiceIDs` below):
///   - control  (write, central -> peripheral): "START" begins the transfer.
///   - metadata (notify, peripheral -> central): one JSON blob {name,size,mime}.
///   - data     (notify, peripheral -> central): raw file bytes, chunked to
///              whatever `maximumUpdateValueLength` allows once negotiated.
///
/// There is no explicit "chunk N of M" framing: BLE notifications on a single
/// characteristic arrive in order over one ATT connection, so the receiver
/// just concatenates bytes and finalizes once `received >= size` from the
/// metadata message — the same pattern already used by the HTTP and WebRTC
/// transports elsewhere in this app.
/// The control-characteristic vocabulary, mirrored from
/// `lib/core/transfer/ble_control_protocol.dart`. See that file for why a
/// receiver announces itself before it starts a transfer.
enum BTControl {
    /// 1 — one file per session. 2 — a list of files carrying relative paths.
    /// 3 — START must carry the session token; a bare START is refused.
    static let generation = 3

    static func capabilities() -> String { "CAPS:\(generation)" }

    /// The generation a command announces, or nil if it is not a CAPS write.
    static func parseCapabilities(_ command: String) -> Int? {
        guard command.hasPrefix("CAPS:") else { return nil }
        return Int(command.dropFirst(5).trimmingCharacters(in: .whitespaces))
    }

    static func isStart(_ command: String?, token: String?) -> Bool {
        guard let command, let token, !token.isEmpty else { return false }
        return command == "START:\(token)"
    }

    /// A START write that failed `isStart` — a device trying to begin a
    /// transfer without the session token, almost always a receiver from
    /// before the token was required.
    static func isUnauthorizedStart(_ command: String?, token: String?) -> Bool {
        guard let command else { return false }
        return (command == "START" || command.hasPrefix("START:"))
            && !isStart(command, token: token)
    }

    static let staleReceiverMessage =
        "The receiving device is on an older version that cannot pair securely "
        + "over Bluetooth. Update it, or send over Wi-Fi."
}

/// One file inside a Bluetooth session.
///
/// `relativePath` is the path the file keeps on the far side, root folder
/// included — `Trip/Day 1/IMG_0042.HEIC`. It is what lets a folder cross this
/// channel as a folder: before it, the bridge could advertise exactly one
/// object of a known size, so a folder had to be zipped into one first and
/// arrived as an archive to unpack.
struct BTSenderItem {
    let path: String
    let name: String
    let relativePath: String
    let size: Int
    let mime: String
}

enum BTServiceIDs {
    static let service = CBUUID(string: "E9C1F384-1D30-4B77-8B8B-9E1A7D5F6B10")
    static let control = CBUUID(string: "E9C1F384-1D30-4B77-8B8B-9E1A7D5F6B11")
    static let metadata = CBUUID(string: "E9C1F384-1D30-4B77-8B8B-9E1A7D5F6B12")
    static let data = CBUUID(string: "E9C1F384-1D30-4B77-8B8B-9E1A7D5F6B13")
}

public class QuickShareBluetoothPlugin: NSObject, FlutterStreamHandler {
    private var eventSink: FlutterEventSink?

    // MARK: Peripheral (sender) state
    private var peripheralManager: CBPeripheralManager?
    private var controlChar: CBMutableCharacteristic?
    private var metadataChar: CBMutableCharacteristic?
    private var dataChar: CBMutableCharacteristic?
    private var sendFileHandle: FileHandle?

    /// The session, in send order, and where the pump has got to inside it.
    private var sendItems: [BTSenderItem] = []
    private var sendItemIndex = 0
    private var sendItemBytesSent = 0

    /// Counted across the whole session, so a folder of forty photos fills one
    /// progress ring rather than forty.
    private var sendTotalBytes: Int = 0
    private var sendBytesSent: Int = 0

    /// The metadata frame for the file about to be sent, still waiting for
    /// room in the notification queue. Its bytes must not start before it
    /// lands, or the receiver files them under the previous file.
    private var pendingMetadataJSON: Data?
    private var subscribedToData = false
    private var subscribedCentral: CBCentral?
    private var transferStarted = false
    private var sendSessionToken: String?

    /// What the receiver said it can take, from its `CAPS:` write. Nil means
    /// it never sent one — a build that stops at the first file of a session.
    private var sendPeerGeneration: Int?
    private let sendChunkQueueLabel = DispatchQueue(label: "quickshare.ble.send")

    // MARK: Central (receiver) state
    private var centralManager: CBCentralManager?
    private var discovered: [String: CBPeripheral] = [:]
    private var targetPeripheral: CBPeripheral?
    private var remoteControlChar: CBCharacteristic?
    private var remoteMetadataChar: CBCharacteristic?
    private var remoteDataChar: CBCharacteristic?
    private var receiveFileHandle: FileHandle?

    /// The destination directory, which stays the destination directory.
    /// It used to be overwritten with the finished file's path, which a
    /// session of more than one file cannot survive.
    private var receiveDirectory: String?
    private var receiveTargetPath: String?

    /// Session totals — every file the sender announced, and every byte of
    /// them that has landed.
    private var receiveTotalBytes: Int = 0
    private var receiveBytesReceived: Int = 0

    /// The file currently open, and where the session is in its list.
    private var receiveFileTotalBytes: Int = 0
    private var receiveFileBytes: Int = 0
    private var receiveItemIndex = 0
    private var receiveItemCount = 1
    private var receivedPaths: [String] = []
    private var receiveFileName = "received_file"
    private var metadataSubscribed = false
    private var dataSubscribed = false
    private var expectedSessionToken: String?

    static func register(with registrar: FlutterPluginRegistrar) {
        let instance = QuickShareBluetoothPlugin()
        let methodChannel = FlutterMethodChannel(name: "quickshare/bluetooth", binaryMessenger: registrar.messenger)
        let eventChannel = FlutterEventChannel(name: "quickshare/bluetooth/events", binaryMessenger: registrar.messenger)
        eventChannel.setStreamHandler(instance)
        methodChannel.setMethodCallHandler { call, result in
            instance.handle(call, result: result)
        }
    }

    // MARK: FlutterStreamHandler

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    private func emit(_ payload: [String: Any]) {
        DispatchQueue.main.async { [weak self] in
            self?.eventSink?(payload)
        }
    }

    // MARK: Method dispatch

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "startAdvertising":
            guard let args = call.arguments as? [String: Any] else {
                result(FlutterError(code: "BAD_ARGS", message: "arguments required", details: nil))
                return
            }
            let items = Self.senderItems(from: args)
            guard !items.isEmpty else {
                result(FlutterError(code: "BAD_ARGS", message: "files or filePath/fileName/fileSize required", details: nil))
                return
            }
            startAdvertising(items: items, sessionToken: args["sessionToken"] as? String)
            result(nil)

        case "stopAdvertising":
            stopAdvertising()
            result(nil)

        case "startScanning":
            startScanning(sessionToken: (call.arguments as? [String: Any])?["sessionToken"] as? String)
            result(nil)

        case "stopScanning":
            stopScanning()
            result(nil)

        case "connect":
            guard let args = call.arguments as? [String: Any],
                  let deviceId = args["deviceId"] as? String,
                  let targetDir = args["targetDir"] as? String
            else {
                result(FlutterError(code: "BAD_ARGS", message: "deviceId/targetDir required", details: nil))
                return
            }
            connect(deviceId: deviceId, targetDir: targetDir)
            result(nil)

        case "cancelTransfer":
            cancelAll()
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Sender (Peripheral)

    /// Reads the session out of the method-channel arguments.
    ///
    /// `files` is what Dart sends now. The single-file keys beside it are what
    /// every earlier build sent, and they are still read so a mismatched pair
    /// of binaries degrades to the one-file session it used to be rather than
    /// failing outright.
    private static func senderItems(from args: [String: Any]) -> [BTSenderItem] {
        if let raw = args["files"] as? [[String: Any]], !raw.isEmpty {
            return raw.compactMap { entry in
                guard let path = entry["filePath"] as? String,
                      let name = entry["fileName"] as? String,
                      let size = entry["fileSize"] as? Int else { return nil }
                return BTSenderItem(
                    path: path,
                    name: name,
                    relativePath: entry["relativePath"] as? String ?? name,
                    size: max(size, 0),
                    mime: entry["mimeType"] as? String ?? "application/octet-stream"
                )
            }
        }
        guard let path = args["filePath"] as? String,
              let name = args["fileName"] as? String,
              let size = args["fileSize"] as? Int else { return [] }
        return [BTSenderItem(
            path: path,
            name: name,
            relativePath: name,
            size: max(size, 0),
            mime: args["mimeType"] as? String ?? "application/octet-stream"
        )]
    }

    private func startAdvertising(items: [BTSenderItem], sessionToken: String?) {
        sendItems = items
        sendItemIndex = 0
        sendItemBytesSent = 0
        sendTotalBytes = items.reduce(0) { $0 + $1.size }
        sendBytesSent = 0
        transferStarted = false
        sendSessionToken = sessionToken
        subscribedToData = false
        pendingMetadataJSON = nil
        sendPeerGeneration = nil
        sendFileHandle = nil

        // Opened here rather than at START so an unreadable file is reported
        // while the sender is still looking at their own screen.
        guard openCurrentSendItem() else { return }
        let fileName = items[0].name

        let control = CBMutableCharacteristic(
            type: BTServiceIDs.control,
            properties: [.write, .writeWithoutResponse],
            value: nil,
            permissions: [.writeable]
        )
        let metadata = CBMutableCharacteristic(
            type: BTServiceIDs.metadata,
            properties: [.notify],
            value: nil,
            permissions: [.readable]
        )
        let data = CBMutableCharacteristic(
            type: BTServiceIDs.data,
            properties: [.notify],
            value: nil,
            permissions: [.readable]
        )
        controlChar = control
        metadataChar = metadata
        dataChar = data

        let service = CBMutableService(type: BTServiceIDs.service, primary: true)
        service.characteristics = [control, metadata, data]

        let manager = CBPeripheralManager(delegate: self, queue: nil)
        peripheralManager = manager
        // Actual add(service)/startAdvertising happens once peripheralManagerDidUpdateState
        // reports .poweredOn — see the delegate method below.
        pendingServiceToAdd = service
        if let sessionToken, !sessionToken.isEmpty {
            pendingDeviceName = "QuickShare-\(String(sessionToken.prefix(8)))"
        } else {
            pendingDeviceName = (fileName as NSString).lastPathComponent
        }
    }

    private var pendingServiceToAdd: CBMutableService?
    private var pendingDeviceName: String?

    private func stopAdvertising() {
        peripheralManager?.stopAdvertising()
        peripheralManager = nil
        sendFileHandle?.closeFile()
        sendFileHandle = nil
        controlChar = nil
        metadataChar = nil
        dataChar = nil
        pendingMetadataJSON = nil
        sendItems = []
        sendItemIndex = 0
        sendItemBytesSent = 0
        transferStarted = false
        sendSessionToken = nil
        sendPeerGeneration = nil
    }

    /// Opens the file at [sendItemIndex] and queues its metadata frame.
    ///
    /// Returns false, having reported the failure, when the file cannot be
    /// read.
    @discardableResult
    private func openCurrentSendItem() -> Bool {
        guard sendItemIndex < sendItems.count else { return false }
        let item = sendItems[sendItemIndex]
        guard let handle = FileHandle(forReadingAtPath: item.path) else {
            emit(["type": "senderFailed", "error": "Could not open file for reading: \(item.path)"])
            return false
        }
        sendFileHandle = handle
        sendItemBytesSent = 0
        let metaJSON: [String: Any] = [
            "name": item.name,
            // The relative path the receiver rebuilds the folder from.
            "path": item.relativePath,
            "size": item.size,
            "mime": item.mime,
            "index": sendItemIndex,
            "count": sendItems.count,
            "sessionBytes": sendTotalBytes,
        ]
        pendingMetadataJSON = try? JSONSerialization.data(withJSONObject: metaJSON)
        return true
    }

    /// Sends as much of the session as the current notification queue allows,
    /// stopping (and relying on `peripheralManagerIsReady(toUpdateSubscribers:)`
    /// to resume) as soon as `updateValue` reports backpressure.
    ///
    /// One loop for the whole list rather than one per file: each item's
    /// metadata goes out, then its bytes, then the next item's metadata. Any
    /// `updateValue` can refuse for want of room, which is why the pending
    /// metadata and the file offset are state rather than locals — this
    /// method has to be able to pick up exactly where it stopped.
    private func pumpSendQueue() {
        guard let manager = peripheralManager,
              let dataChar = dataChar,
              let metaChar = metadataChar else { return }

        // On macOS, negotiated MTU is exposed per-subscriber on CBCentral, not
        // on CBPeripheralManager (that shortcut only exists on iOS). Fall back
        // to a conservative default if we somehow don't have a central yet.
        let mtu = subscribedCentral?.maximumUpdateValueLength ?? 182
        let chunkSize = max(mtu - 3, 20)

        while sendItemIndex < sendItems.count {
            if let pending = pendingMetadataJSON {
                if !manager.updateValue(pending, for: metaChar, onSubscribedCentrals: nil) {
                    return
                }
                pendingMetadataJSON = nil
            }

            let item = sendItems[sendItemIndex]
            guard let handle = sendFileHandle else { return }

            while sendItemBytesSent < item.size {
                let chunk = handle.readData(ofLength: chunkSize)
                if chunk.isEmpty { break }

                let ok = manager.updateValue(chunk, for: dataChar, onSubscribedCentrals: nil)
                if !ok {
                    // Queue is full; rewind so this chunk is resent once ready.
                    handle.seek(toFileOffset: UInt64(sendItemBytesSent))
                    return
                }

                sendItemBytesSent += chunk.count
                sendBytesSent += chunk.count
                emit(["type": "senderProgress", "sent": sendBytesSent, "total": sendTotalBytes])
            }

            guard sendItemBytesSent >= item.size else {
                handle.closeFile()
                sendFileHandle = nil
                emit(["type": "senderFailed", "error": "\(item.name) ended after \(sendItemBytesSent) of \(item.size) bytes"])
                return
            }

            handle.closeFile()
            sendFileHandle = nil
            sendItemIndex += 1
            if sendItemIndex < sendItems.count {
                guard openCurrentSendItem() else { return }
            }
        }

        emit(["type": "senderCompleted"])
    }

    // MARK: - Receiver (Central)

    private func startScanning(sessionToken: String? = nil) {
        discovered.removeAll()
        expectedSessionToken = sessionToken
        let manager = centralManager ?? CBCentralManager(delegate: self, queue: nil)
        centralManager = manager
        if manager.state == .poweredOn {
            manager.scanForPeripherals(withServices: [BTServiceIDs.service], options: nil)
        } else {
            pendingStartScan = true
        }
    }

    private var pendingStartScan = false

    private func stopScanning() {
        centralManager?.stopScan()
        pendingStartScan = false
    }

    private func connect(deviceId: String, targetDir: String) {
        guard let peripheral = discovered[deviceId] else {
            emit(["type": "receiverFailed", "error": "Device no longer available"])
            return
        }
        centralManager?.stopScan()
        targetPeripheral = peripheral
        receiveDirectory = targetDir
        receiveTargetPath = nil
        receiveTotalBytes = 0
        receiveBytesReceived = 0
        receiveFileTotalBytes = 0
        receiveFileBytes = 0
        receiveItemIndex = 0
        receiveItemCount = 1
        receivedPaths = []
        peripheral.delegate = self
        emit(["type": "connecting"])
        centralManager?.connect(peripheral, options: nil)
    }

    private func cancelAll() {
        stopAdvertising()
        stopScanning()
        if let p = targetPeripheral {
            centralManager?.cancelPeripheralConnection(p)
        }
        receiveFileHandle?.closeFile()
        receiveFileHandle = nil
        targetPeripheral = nil
    }

    private func uniquePath(_ path: String) -> String {
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) { return path }
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        let dir = url.deletingLastPathComponent()
        var counter = 1
        var candidate = path
        while fm.fileExists(atPath: candidate) {
            let suffix = ext.isEmpty ? "\(stem) (\(counter))" : "\(stem) (\(counter)).\(ext)"
            candidate = dir.appendingPathComponent(suffix).path
            counter += 1
        }
        return candidate
    }

    /// Where a file announced as [relative] is written, under [directory].
    ///
    /// Every segment came off the wire, so every segment is put through the
    /// same filename cleaner as a flat name, and `.`/`..` are dropped rather
    /// than resolved — a sender cannot name its way out of the destination.
    /// The containment check afterwards is deliberate belt and braces.
    private func resolveReceivePath(_ relative: String, in directory: String) -> String? {
        let segments = relative
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .map(String.init)
            .filter { $0 != "." && $0 != ".." && !$0.isEmpty }
            .map(sanitizeFileName)

        let root = URL(fileURLWithPath: directory).standardizedFileURL
        var url = root
        for segment in segments.isEmpty ? ["received_file"] : segments {
            url.appendPathComponent(segment)
        }
        let resolved = url.standardizedFileURL
        guard resolved.path.hasPrefix(root.path + "/") else { return nil }
        return resolved.path
    }

    /// Flushes and records whatever file is open, exactly once.
    private func sealCurrentReceiveFile() {
        receiveFileHandle?.closeFile()
        receiveFileHandle = nil
        if let path = receiveTargetPath, !receivedPaths.contains(path) {
            receivedPaths.append(path)
        }
    }

    private func sanitizeFileName(_ name: String) -> String {
        let base = (name as NSString).lastPathComponent
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let cleaned = base.components(separatedBy: invalid).joined(separator: "_").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "received_file" : cleaned
    }
}

// MARK: - CBPeripheralManagerDelegate

extension QuickShareBluetoothPlugin: CBPeripheralManagerDelegate {
    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral.state == .poweredOn else {
            if peripheral.state == .unauthorized || peripheral.state == .unsupported {
                emit(["type": "senderFailed", "error": "Bluetooth is not available or not authorized"])
            }
            return
        }
        if let service = pendingServiceToAdd {
            peripheral.add(service)
        }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error = error {
            emit(["type": "senderFailed", "error": "Failed to publish BLE service: \(error.localizedDescription)"])
            return
        }
        let name = pendingDeviceName ?? "QuickShare"
        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [BTServiceIDs.service],
            CBAdvertisementDataLocalNameKey: name,
        ])
        emit(["type": "advertisingStarted"])
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        if characteristic.uuid == BTServiceIDs.data {
            subscribedToData = true
            subscribedCentral = central
        }
        emit(["type": "centralConnected"])
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            let command = request.value.flatMap { String(data: $0, encoding: .utf8) }
            guard request.characteristic.uuid == BTServiceIDs.control else {
                peripheral.respond(to: request, withResult: .success)
                continue
            }

            // Always ahead of START, so it is on record before the decision
            // about what this session may send is taken.
            if let command, let generation = BTControl.parseCapabilities(command) {
                sendPeerGeneration = generation
                peripheral.respond(to: request, withResult: .success)
                continue
            }

            if BTControl.isStart(command, token: sendSessionToken) {
                peripheral.respond(to: request, withResult: .success)
                beginTransferIfReady()
            } else if BTControl.isUnauthorizedStart(command, token: sendSessionToken) {
                // A START without the session token — a receiver too old to
                // pair securely. Refuse and say why, rather than leaving both
                // sides waiting on a transfer that will never begin.
                peripheral.respond(to: request, withResult: .insufficientAuthentication)
                emit(["type": "senderFailed", "error": BTControl.staleReceiverMessage])
            } else {
                peripheral.respond(to: request, withResult: .success)
            }
        }
    }

    private func beginTransferIfReady() {
        guard !transferStarted, subscribedToData, metadataChar != nil, pendingMetadataJSON != nil else { return }

        // A receiver older than this protocol treats the first file's last
        // byte as the end of the transfer and disconnects. It then shows a
        // completed transfer holding one file, with nothing to say a folder
        // was sent — which is worse than any error, because nobody goes
        // looking for what is missing. One file is still sent to anyone.
        if sendItems.count > 1, (sendPeerGeneration ?? 1) < BTControl.generation {
            transferStarted = true
            emit([
                "type": "senderFailed",
                "error": "The receiving device is on an older version that can only accept one file over Bluetooth. Update it, or send over Wi-Fi.",
            ])
            return
        }

        transferStarted = true
        pumpSendQueue()
    }

    public func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        pumpSendQueue()
    }
}

// MARK: - CBCentralManagerDelegate

extension QuickShareBluetoothPlugin: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn, pendingStartScan {
            pendingStartScan = false
            central.scanForPeripherals(withServices: [BTServiceIDs.service], options: nil)
        } else if central.state == .unauthorized || central.state == .unsupported {
            emit(["type": "receiverFailed", "error": "Bluetooth is not available or not authorized"])
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advertisedName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "Unknown device"
        if let expectedSessionToken,
           !advertisedName.contains(String(expectedSessionToken.prefix(8))) &&
           advertisedName.hasPrefix("QuickShare-") {
            return
        }
        let id = peripheral.identifier.uuidString
        if discovered[id] == nil {
            discovered[id] = peripheral
            emit(["type": "deviceDiscovered", "id": id, "name": advertisedName])
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([BTServiceIDs.service])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        emit(["type": "receiverFailed", "error": "Failed to connect: \(error?.localizedDescription ?? "unknown error")"])
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if receiveBytesReceived < receiveTotalBytes || receiveTotalBytes == 0 {
            if targetPeripheral === peripheral {
                emit(["type": "receiverFailed", "error": "Sender disconnected before the transfer finished"])
            }
        }
    }
}

// MARK: - CBPeripheralDelegate (central-side: talking to the remote peripheral)

extension QuickShareBluetoothPlugin: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == BTServiceIDs.service }) else {
            emit(["type": "receiverFailed", "error": "QuickShare service not found on device"])
            return
        }
        peripheral.discoverCharacteristics([BTServiceIDs.control, BTServiceIDs.metadata, BTServiceIDs.data], for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics else { return }
        for c in chars {
            switch c.uuid {
            case BTServiceIDs.control: remoteControlChar = c
            case BTServiceIDs.metadata:
                remoteMetadataChar = c
                peripheral.setNotifyValue(true, for: c)
            case BTServiceIDs.data:
                remoteDataChar = c
                peripheral.setNotifyValue(true, for: c)
            default: break
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic.uuid == BTServiceIDs.metadata { metadataSubscribed = true }
        if characteristic.uuid == BTServiceIDs.data { dataSubscribed = true }

        if metadataSubscribed, dataSubscribed, let controlChar = remoteControlChar {
            let writeType: CBCharacteristicWriteType = controlChar.properties.contains(.write) ? .withResponse : .withoutResponse

            // Say what this build can take, before START rather than after. A
            // sender that reaches START without having seen this knows the far
            // side is old and refuses to half-deliver a folder to it.
            //
            // Senders up to v1.0.10 answer this with success or an ATT error
            // depending on their platform, and then carry on waiting for
            // START; neither is a failed connection. Any error lands in
            // didWriteValueFor, which this class deliberately does not
            // implement.
            peripheral.writeValue(Data(BTControl.capabilities().utf8), for: controlChar, type: writeType)

            guard let token = expectedSessionToken, !token.isEmpty else {
                // No token means no QR was scanned — there is nothing to
                // authorise the transfer with, and a bare START is no longer
                // accepted. Stop rather than write a command that gets refused.
                emit(["type": "receiverFailed", "error": "Missing session token — scan the QR code again."])
                return
            }
            peripheral.writeValue(Data("START:\(token)".utf8), for: controlChar, type: writeType)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let value = characteristic.value else { return }

        if characteristic.uuid == BTServiceIDs.metadata {
            guard
                let json = try? JSONSerialization.jsonObject(with: value) as? [String: Any],
                let name = json["name"] as? String,
                let size = json["size"] as? Int
            else {
                emit(["type": "receiverFailed", "error": "Malformed metadata from sender"])
                return
            }

            // A metadata frame is this channel's only end-of-file marker:
            // whatever is open belongs to the item before this one.
            sealCurrentReceiveFile()

            receiveFileName = sanitizeFileName(name)
            receiveFileTotalBytes = size
            receiveFileBytes = 0
            receiveItemIndex = json["index"] as? Int ?? 0
            // A sender that says nothing is a sender with one file, which is
            // what every build before folders could carry.
            receiveItemCount = json["count"] as? Int ?? 1
            if receiveItemIndex <= 0 {
                receiveBytesReceived = 0
                receivedPaths = []
                receiveTotalBytes = json["sessionBytes"] as? Int ?? size
            }

            let dir = receiveDirectory ?? NSTemporaryDirectory()
            let relative = json["path"] as? String ?? name
            guard let target = resolveReceivePath(relative, in: dir) else {
                emit(["type": "receiverFailed", "error": "Path traversal detected in \"\(relative)\""])
                return
            }
            do {
                // The folder the sender kept has to exist before its first
                // file can go into it, and directories are created as their
                // contents arrive.
                try FileManager.default.createDirectory(
                    atPath: (target as NSString).deletingLastPathComponent,
                    withIntermediateDirectories: true
                )
            } catch {
                emit(["type": "receiverFailed", "error": "Cannot create destination directory: \(error.localizedDescription)"])
                return
            }
            let path = uniquePath(target)
            FileManager.default.createFile(atPath: path, contents: nil)
            receiveFileHandle = FileHandle(forWritingAtPath: path)
            receiveTargetPath = path

            emit(["type": "metadataReceived", "name": receiveFileName, "size": receiveTotalBytes])
            return
        }

        if characteristic.uuid == BTServiceIDs.data {
            receiveFileHandle?.write(value)
            receiveFileBytes += value.count
            receiveBytesReceived += value.count
            emit(["type": "receiverProgress", "received": receiveBytesReceived, "total": receiveTotalBytes])

            if receiveFileTotalBytes > 0, receiveFileBytes >= receiveFileTotalBytes {
                sealCurrentReceiveFile()
                // The last item the sender announced, with all of its bytes
                // in: that is the session, and nothing further is coming.
                if receiveItemIndex >= receiveItemCount - 1 {
                    emit(["type": "receiverCompleted", "path": receivedPaths.first ?? receiveTargetPath ?? ""])
                    if let p = targetPeripheral {
                        centralManager?.cancelPeripheralConnection(p)
                    }
                }
            }
        }
    }
}
