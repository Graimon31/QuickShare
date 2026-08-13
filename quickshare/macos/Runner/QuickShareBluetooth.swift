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
    private var sendTotalBytes: Int = 0
    private var sendBytesSent: Int = 0
    private var pendingMetadataJSON: Data?
    private var subscribedToData = false
    private var subscribedCentral: CBCentral?
    private var transferStarted = false
    private var sendSessionToken: String?
    private let sendChunkQueueLabel = DispatchQueue(label: "quickshare.ble.send")

    // MARK: Central (receiver) state
    private var centralManager: CBCentralManager?
    private var discovered: [String: CBPeripheral] = [:]
    private var targetPeripheral: CBPeripheral?
    private var remoteControlChar: CBCharacteristic?
    private var remoteMetadataChar: CBCharacteristic?
    private var remoteDataChar: CBCharacteristic?
    private var receiveFileHandle: FileHandle?
    private var receiveTargetPath: String?
    private var receiveTotalBytes: Int = 0
    private var receiveBytesReceived: Int = 0
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
            guard let args = call.arguments as? [String: Any],
                  let path = args["filePath"] as? String,
                  let name = args["fileName"] as? String,
                  let size = args["fileSize"] as? Int
            else {
                result(FlutterError(code: "BAD_ARGS", message: "filePath/fileName/fileSize required", details: nil))
                return
            }
            startAdvertising(
                filePath: path,
                fileName: name,
                fileSize: size,
                mime: args["mimeType"] as? String ?? "application/octet-stream",
                sessionToken: args["sessionToken"] as? String
            )
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

    private func startAdvertising(filePath: String, fileName: String, fileSize: Int, mime: String, sessionToken: String?) {
        sendTotalBytes = fileSize
        sendBytesSent = 0
        transferStarted = false
        sendSessionToken = sessionToken
        subscribedToData = false
        sendFileHandle = FileHandle(forReadingAtPath: filePath)

        guard sendFileHandle != nil else {
            emit(["type": "senderFailed", "error": "Could not open file for reading: \(filePath)"])
            return
        }

        let metaJSON: [String: Any] = ["name": fileName, "size": fileSize, "mime": mime]
        pendingMetadataJSON = try? JSONSerialization.data(withJSONObject: metaJSON)

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
        transferStarted = false
        sendSessionToken = nil
    }

    /// Sends as much of the file as the current notification queue allows,
    /// stopping (and relying on `peripheralManagerIsReady(toUpdateSubscribers:)`
    /// to resume) as soon as `updateValue` reports backpressure.
    private func pumpSendQueue() {
        guard let manager = peripheralManager, let dataChar = dataChar, let handle = sendFileHandle else { return }

        // On macOS, negotiated MTU is exposed per-subscriber on CBCentral, not
        // on CBPeripheralManager (that shortcut only exists on iOS). Fall back
        // to a conservative default if we somehow don't have a central yet.
        let mtu = subscribedCentral?.maximumUpdateValueLength ?? 182
        let chunkSize = max(mtu - 3, 20)

        while sendBytesSent < sendTotalBytes {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }

            let ok = manager.updateValue(chunk, for: dataChar, onSubscribedCentrals: nil)
            if !ok {
                // Queue is full; rewind so this chunk is resent once ready.
                let newOffset = UInt64(sendBytesSent)
                handle.seek(toFileOffset: newOffset)
                return
            }

            sendBytesSent += chunk.count
            emit(["type": "senderProgress", "sent": sendBytesSent, "total": sendTotalBytes])
        }

        if sendBytesSent >= sendTotalBytes {
            emit(["type": "senderCompleted"])
            sendFileHandle?.closeFile()
            sendFileHandle = nil
        }
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
        receiveTargetPath = targetDir
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
            let tokenCommand = sendSessionToken.map { "START:\($0)" }
            let isValidStart = command == "START" || command == tokenCommand
            if request.characteristic.uuid == BTServiceIDs.control, isValidStart {
                peripheral.respond(to: request, withResult: .success)
                beginTransferIfReady()
            } else {
                peripheral.respond(to: request, withResult: .success)
            }
        }
    }

    private func beginTransferIfReady() {
        guard !transferStarted, subscribedToData, let metaChar = metadataChar, let metaJSON = pendingMetadataJSON else { return }
        transferStarted = true
        _ = peripheralManager?.updateValue(metaJSON, for: metaChar, onSubscribedCentrals: nil)
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
            let command = expectedSessionToken.map { "START:\($0)" } ?? "START"
            peripheral.writeValue(Data(command.utf8), for: controlChar, type: writeType)
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
            receiveFileName = sanitizeFileName(name)
            receiveTotalBytes = size
            receiveBytesReceived = 0

            let dir = receiveTargetPath ?? NSTemporaryDirectory()
            let path = uniquePath((dir as NSString).appendingPathComponent(receiveFileName))
            FileManager.default.createFile(atPath: path, contents: nil)
            receiveFileHandle = FileHandle(forWritingAtPath: path)
            receiveTargetPath = path // now holds the final file path, not just the dir

            emit(["type": "metadataReceived", "name": receiveFileName, "size": size])
            return
        }

        if characteristic.uuid == BTServiceIDs.data {
            receiveFileHandle?.write(value)
            receiveBytesReceived += value.count
            emit(["type": "receiverProgress", "received": receiveBytesReceived, "total": receiveTotalBytes])

            if receiveTotalBytes > 0, receiveBytesReceived >= receiveTotalBytes {
                receiveFileHandle?.closeFile()
                receiveFileHandle = nil
                emit(["type": "receiverCompleted", "path": receiveTargetPath ?? ""])
                if let p = targetPeripheral {
                    centralManager?.cancelPeripheralConnection(p)
                }
            }
        }
    }
}
