import Cocoa
import FlutterMacOS
import CoreBluetooth

/// Native CoreBluetooth bridge for QuickShare's Bluetooth rendezvous.
///
///   Sender   = CBPeripheralManager, advertises a custom service and, once a
///              receiver has subscribed and written `START:<token>`, tells
///              Dart so; Dart then negotiates a Wi-Fi link with it over the
///              metadata characteristic.
///   Receiver = CBCentralManager, scans for that service, connects,
///              subscribes, writes CAPS / HELLO / `START:<token>`, and hands
///              the sender's frames to Dart.
///
/// **No file crosses this bridge.** Since protocol generation 4 the bytes
/// travel over a Wi-Fi link the two devices raise between them, and the owner's
/// decision is that a file does not travel over plain Bluetooth at all. What
/// used to push and receive them — a notification pump on the sender, a
/// partial-file writer on the receiver — was unreachable, and is gone.
///
/// GATT layout (see `BTServiceIDs` below):
///   - control  (write, central -> peripheral): CAPS, HELLO, KEX, AP, START.
///   - metadata (notify, peripheral -> central): the `link` and `serve` frames.
///   - data     (notify, peripheral -> central): subscribed to, and nothing is
///              ever sent on it. The receiver's subscription is how the sender
///              learns it is fully connected.
/// The control-characteristic vocabulary, mirrored from
/// `lib/core/transfer/ble_control_protocol.dart`. See that file for why a
/// receiver announces itself before it starts a transfer.
enum BTControl {
    /// 1 — one file per session. 2 — a list of files carrying relative paths.
    /// 3 — START must carry the session token; a bare START is refused.
    /// 4 — the direct-link generation: the file never travels this channel;
    /// after the rendezvous the two devices raise a Wi-Fi link of their own.
    static let generation = 4

    static func capabilities() -> String { "CAPS:\(generation)" }

    /// Written by a receiver ahead of its START, to say what it calls itself.
    /// The sender reads the name only to tell an Apple receiver from the rest.
    /// Mirrors BleControlProtocol.hello in Dart.
    static let helloPrefix = "HELLO:"

    static func hello(_ deviceName: String) -> String { "\(helloPrefix)\(deviceName)" }

    static func parseHello(_ command: String?) -> String? {
        guard let command, command.hasPrefix(helloPrefix) else { return nil }
        let name = String(command.dropFirst(helloPrefix.count))
            .trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.count <= 64 else { return nil }
        return name
    }

    /// Receiver -> sender: the credentials of the network it raised, sealed.
    ///
    /// Opaque here on purpose. They used to cross this characteristic as the
    /// pair itself, on a link with no bonding behind it, which put the WPA
    /// passphrase of a live network in a packet anything in range could read.
    /// This bridge now only carries the blob; `LinkSecret` in Dart is what
    /// seals and opens it, and what checks the 802.11 limits afterwards.
    /// Mirrors BleControlProtocol.parseApOffer.
    static let apPrefix = "AP:"

    static func apOffer(_ sealed: String) -> String { "\(apPrefix)\(sealed)" }

    static func parseApOffer(_ command: String?) -> String? {
        guard let command, command.hasPrefix(apPrefix) else { return nil }
        let sealed = String(command.dropFirst(apPrefix.count))
            .trimmingCharacters(in: .whitespaces)
        guard !sealed.isEmpty, sealed.count <= 512 else { return nil }
        return sealed
    }

    /// Either side -> the other: a public half for this negotiation. Readable
    /// by anyone listening, which is the point: what the two sides derive
    /// from the pair never crosses the wire.
    static let kexPrefix = "KEX:"

    static func keyExchange(_ publicKey: String) -> String {
        "\(kexPrefix)\(publicKey)"
    }

    static func parseKeyExchange(_ command: String?) -> String? {
        guard let command, command.hasPrefix(kexPrefix) else { return nil }
        let key = String(command.dropFirst(kexPrefix.count))
            .trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, key.count <= 64 else { return nil }
        return key
    }

    /// Shown when a receiver below generation 4 asks for a transfer: it only
    /// knows this channel, which no longer carries files.
    static let directLinkRequiredMessage =
        "The receiving device is on an older version that can only receive "
        + "over Bluetooth. Update it, and the transfer moves to a direct "
        + "Wi-Fi link."

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
    private var subscribedToData = false
    private var subscribedToMetadata = false
    private var transferStarted = false
    private var sendSessionToken: String?

    /// What the receiver said it can take, from its `CAPS:` write. Nil means
    /// it never sent one.
    private var sendPeerGeneration: Int?

    // MARK: Central (receiver) state
    private var centralManager: CBCentralManager?
    private var discovered: [String: CBPeripheral] = [:]
    private var targetPeripheral: CBPeripheral?
    private var remoteControlChar: CBCharacteristic?
    private var remoteMetadataChar: CBCharacteristic?
    private var remoteDataChar: CBCharacteristic?
    private var metadataSubscribed = false
    private var dataSubscribed = false
    private var expectedSessionToken: String?
    private var expectedPublicId: String?
    private var centralConnectTimeoutTimer: Timer?

    /// A sender that is pushing a file over this channel is an older build.
    /// Said once: its file is thousands of notifications.
    private var reportedStaleSender = false

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
            startAdvertising(sessionToken: args["sessionToken"] as? String,
                             publicId: args["publicId"] as? String)
            result(nil)

        case "stopAdvertising":
            stopAdvertising()
            result(nil)

        // A generation-4 session negotiates over this channel instead of
        // transferring over it: the "link" frame says which side raises the
        // Wi-Fi network, the "serve" frame says where on it the file is.
        case "sendLinkFrame":
            guard let args = call.arguments as? [String: Any],
                  let frame = args["frame"] as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: frame)
            else {
                result(FlutterError(code: "BAD_ARGS", message: "frame required", details: nil))
                return
            }
            guard let metadata = metadataChar, let manager = peripheralManager else {
                result(FlutterError(code: "UNAVAILABLE", message: "no link channel is up", details: nil))
                return
            }
            if manager.updateValue(data, for: metadata, onSubscribedCentrals: nil) {
                result(nil)
            } else {
                result(FlutterError(code: "BUSY", message: "the notification queue is full", details: nil))
            }

        // The receiver's half of the negotiation: the credentials of the
        // network it raised, written back over the control characteristic.
        case "sendApOffer":
            guard let args = call.arguments as? [String: Any],
                  let sealed = args["sealed"] as? String
            else {
                result(FlutterError(code: "BAD_ARGS", message: "sendApOffer needs sealed credentials", details: nil))
                return
            }
            writeControl(BTControl.apOffer(sealed), result)

        case "sendKeyExchange":
            guard let args = call.arguments as? [String: Any],
                  let key = args["key"] as? String
            else {
                result(FlutterError(code: "BAD_ARGS", message: "sendKeyExchange needs a key", details: nil))
                return
            }
            writeControl(BTControl.keyExchange(key), result)

        case "startScanning":
            let scanArgs = call.arguments as? [String: Any]
            startScanning(sessionToken: scanArgs?["sessionToken"] as? String,
                          publicId: scanArgs?["publicId"] as? String)
            result(nil)

        case "stopScanning":
            stopScanning()
            result(nil)

        case "connect":
            guard let args = call.arguments as? [String: Any],
                  let deviceId = args["deviceId"] as? String
            else {
                result(FlutterError(code: "BAD_ARGS", message: "deviceId required", details: nil))
                return
            }
            connect(deviceId: deviceId)
            result(nil)

        case "cancelTransfer":
            cancelAll()
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Sender (Peripheral)

    private func startAdvertising(sessionToken: String?, publicId: String? = nil) {
        stopAdvertising()
        transferStarted = false
        sendSessionToken = sessionToken
        subscribedToData = false
        subscribedToMetadata = false
        sendPeerGeneration = nil

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

        pendingServiceToAdd = service
        if let publicId, !publicId.isEmpty {
            pendingDeviceName = "QuickShare-\(publicId)"
        } else {
            pendingDeviceName = "QuickShare-directdrop"
        }

        let manager = CBPeripheralManager(delegate: self, queue: nil)
        peripheralManager = manager
        if manager.state == .poweredOn {
            pendingServiceToAdd = nil
            manager.add(service)
        }
    }

    private var pendingServiceToAdd: CBMutableService?
    private var pendingDeviceName: String?

    private func stopAdvertising() {
        peripheralManager?.stopAdvertising()
        peripheralManager = nil
        controlChar = nil
        metadataChar = nil
        dataChar = nil
        subscribedToData = false
        subscribedToMetadata = false
        transferStarted = false
        sendSessionToken = nil
        sendPeerGeneration = nil
    }

    // MARK: - Receiver (Central)

    /// Writes one control command to the sender this device is connected to.
    private var pendingControlWrites: [String] = []

    private func writeControl(_ command: String, _ result: @escaping FlutterResult) {
        guard let peripheral = targetPeripheral else {
            result(FlutterError(code: "UNAVAILABLE", message: "no sender is connected", details: nil))
            return
        }
        guard let control = remoteControlChar, metadataSubscribed, dataSubscribed else {
            pendingControlWrites.append(command)
            result(nil)
            return
        }
        let type: CBCharacteristicWriteType =
            control.properties.contains(.write) ? .withResponse : .withoutResponse
        peripheral.writeValue(Data(command.utf8), for: control, type: type)
        result(nil)
    }

    private func startScanning(sessionToken: String? = nil, publicId: String? = nil) {
        discovered.removeAll()
        expectedSessionToken = sessionToken
        expectedPublicId = publicId
        let manager = centralManager ?? CBCentralManager(delegate: self, queue: nil)
        centralManager = manager
        let options: [String: Any] = [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        if manager.state == .poweredOn {
            manager.scanForPeripherals(withServices: [BTServiceIDs.service], options: options)
        } else {
            pendingStartScan = true
        }
    }

    private var pendingStartScan = false

    private func stopScanning() {
        centralManager?.stopScan()
        pendingStartScan = false
    }

    private func connect(deviceId: String) {
        guard let peripheral = discovered[deviceId] else {
            emit(["type": "receiverFailed", "error": "Device no longer available"])
            return
        }
        centralManager?.stopScan()
        targetPeripheral = peripheral
        remoteControlChar = nil
        remoteMetadataChar = nil
        remoteDataChar = nil
        metadataSubscribed = false
        dataSubscribed = false
        reportedStaleSender = false
        pendingControlWrites.removeAll()
        peripheral.delegate = self

        centralConnectTimeoutTimer?.invalidate()
        centralConnectTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            guard let self = self, self.targetPeripheral != nil, self.remoteControlChar == nil else { return }
            if let p = self.targetPeripheral {
                self.centralManager?.cancelPeripheralConnection(p)
            }
            self.emit([
                "type": "receiverFailed",
                "error": "Failed to connect: Connection attempt timed out",
                "code": "timeout"
            ])
        }

        centralManager?.connect(peripheral, options: nil)
    }

    private func cancelAll() {
        centralConnectTimeoutTimer?.invalidate()
        centralConnectTimeoutTimer = nil
        stopAdvertising()
        stopScanning()
        if let p = targetPeripheral {
            centralManager?.cancelPeripheralConnection(p)
        }
        targetPeripheral = nil
        remoteControlChar = nil
        remoteMetadataChar = nil
        remoteDataChar = nil
        metadataSubscribed = false
        dataSubscribed = false
        pendingControlWrites.removeAll()
        discovered.removeAll()
    }

    /// A sender that writes a file's metadata or bytes to this channel is a
    /// build from before the direct link. It is told so, once, in words the
    /// person can act on; nothing it sends is written anywhere.
    private func refuseStaleSender() {
        guard !reportedStaleSender else { return }
        reportedStaleSender = true
        emit(["type": "receiverFailed",
              "error": "The sending device is on an older version that sends files over Bluetooth itself. "
                  + "This version receives them over a direct Wi-Fi link only. Update the sending device.",
              "code": "senderTooOldForDirectLink"])
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
            pendingServiceToAdd = nil
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
        if characteristic.uuid == BTServiceIDs.metadata {
            subscribedToMetadata = true
        }
        if characteristic.uuid == BTServiceIDs.data {
            subscribedToData = true
        }
        emit(["type": "centralConnected"])
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        if characteristic.uuid == BTServiceIDs.metadata {
            subscribedToMetadata = false
        }
        if characteristic.uuid == BTServiceIDs.data {
            subscribedToData = false
        }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            let command = request.value.flatMap { String(data: $0, encoding: .utf8) }
            guard request.characteristic.uuid == BTServiceIDs.control else {
                peripheral.respond(to: request, withResult: .success)
                continue
            }

            // Always ahead of START, so it is on record before the decision
            // about what this session may do is taken.
            if let command, let generation = BTControl.parseCapabilities(command) {
                sendPeerGeneration = generation
                peripheral.respond(to: request, withResult: .success)
                continue
            }

            // The name a receiver gives itself, written ahead of its START.
            // Dart reads it only to tell an Apple receiver from the rest;
            // nothing is listed and nothing starts because of it.
            if let name = BTControl.parseHello(command) {
                if sendPeerGeneration == nil {
                    sendPeerGeneration = BTControl.generation
                }
                peripheral.respond(to: request, withResult: .success)
                emit(["type": "receiverAnnounced", "name": name])
                continue
            }

            // A receiver that raised the network itself says where. What is
            // inside is sealed; opening it is the coordinator's business.
            if let sealed = BTControl.parseApOffer(command) {
                peripheral.respond(to: request, withResult: .success)
                emit(["type": "apOffer", "sealed": sealed])
                continue
            }

            // The far side's public half for the negotiation.
            if let key = BTControl.parseKeyExchange(command) {
                peripheral.respond(to: request, withResult: .success)
                emit(["type": "peerKey", "key": key])
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
                emit(["type": "senderFailed",
                      "error": BTControl.staleReceiverMessage,
                      "code": "receiverTooOldToPair"])
            } else {
                peripheral.respond(to: request, withResult: .success)
            }
        }
    }

    private func beginTransferIfReady() {
        guard !transferStarted, metadataChar != nil else { return }

        // Generation 4 is where the bytes left this radio. A peer from this
        // generation on gets the Wi-Fi link negotiated over this channel —
        // Dart runs that from the receiverReady event. A peer below it gets
        // told to update rather than sent anything.
        let peerGen = sendPeerGeneration ?? BTControl.generation
        if peerGen >= BTControl.generation {
            transferStarted = true
            emit(["type": "receiverReady"])
        } else {
            guard subscribedToData else { return }
            transferStarted = true
            // The error text is English, for the log; the code is what the
            // Dart side translates for the screen.
            emit(["type": "senderFailed",
                  "error": BTControl.directLinkRequiredMessage,
                  "code": "receiverTooOldForDirectLink"])
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension QuickShareBluetoothPlugin: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn, pendingStartScan {
            pendingStartScan = false
            central.scanForPeripherals(withServices: [BTServiceIDs.service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        } else if central.state == .unauthorized || central.state == .unsupported {
            emit(["type": "receiverFailed", "error": "Bluetooth is not available or not authorized"])
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advertisedName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "Unknown device"
        // What a sender advertises is the session's public identifier, derived
        // from the code and carrying nothing secret. A device with no
        // `QuickShare-` name at all — a Windows PC or an Android phone, which
        // cannot carry one beside the service UUID — is accepted: the scan is
        // already filtered to our service, and the START token is what
        // authenticates. Earlier builds advertised the first eight characters
        // of the token instead, so that match stays as the fallback —
        // dropping it would make this build unable to see them.
        if advertisedName.hasPrefix("QuickShare-") {
            if let expectedPublicId, !expectedPublicId.isEmpty {
                if !advertisedName.contains(expectedPublicId) { return }
            } else if let expectedSessionToken,
                      !advertisedName.contains(String(expectedSessionToken.prefix(8))) {
                return
            }
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
        centralConnectTimeoutTimer?.invalidate()
        centralConnectTimeoutTimer = nil
        var code = "connectFailed"
        if let nsError = error as NSError?, nsError.domain == CBErrorDomain, nsError.code == 14 {
            code = "peerRemovedPairingInformation"
        }
        emit([
            "type": "receiverFailed",
            "error": "Failed to connect: \(error?.localizedDescription ?? "unknown error")",
            "code": code
        ])
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        centralConnectTimeoutTimer?.invalidate()
        centralConnectTimeoutTimer = nil
        targetPeripheral = nil
        remoteControlChar = nil
        remoteMetadataChar = nil
        remoteDataChar = nil
        metadataSubscribed = false
        dataSubscribed = false
        pendingControlWrites.removeAll()
        discovered.removeAll()

        // Whether this matters is Dart's call: before the serve frame it ends
        // the session, after it nothing is waiting on the radio.
        emit(["type": "receiverDisconnected"])
    }
}

// MARK: - CBPeripheralDelegate (central-side: talking to the remote peripheral)

extension QuickShareBluetoothPlugin: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            centralConnectTimeoutTimer?.invalidate()
            centralConnectTimeoutTimer = nil
            emit(["type": "receiverFailed", "error": "Service discovery failed: \(error.localizedDescription)"])
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == BTServiceIDs.service }) else {
            centralConnectTimeoutTimer?.invalidate()
            centralConnectTimeoutTimer = nil
            emit(["type": "receiverFailed", "error": "QuickShare service not found on device"])
            return
        }
        peripheral.discoverCharacteristics([BTServiceIDs.control, BTServiceIDs.metadata, BTServiceIDs.data], for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            centralConnectTimeoutTimer?.invalidate()
            centralConnectTimeoutTimer = nil
            emit(["type": "receiverFailed", "error": "Characteristic discovery failed: \(error.localizedDescription)"])
            return
        }
        guard let chars = service.characteristics else {
            centralConnectTimeoutTimer?.invalidate()
            centralConnectTimeoutTimer = nil
            emit(["type": "receiverFailed", "error": "No characteristics found on device"])
            return
        }
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
        if let error = error {
            centralConnectTimeoutTimer?.invalidate()
            centralConnectTimeoutTimer = nil
            emit(["type": "receiverFailed", "error": "Failed to subscribe to notifications: \(error.localizedDescription)"])
            return
        }

        if characteristic.uuid == BTServiceIDs.metadata { metadataSubscribed = true }
        if characteristic.uuid == BTServiceIDs.data { dataSubscribed = true }

        if metadataSubscribed, dataSubscribed, let controlChar = remoteControlChar {
            centralConnectTimeoutTimer?.invalidate()
            centralConnectTimeoutTimer = nil
            let writeType: CBCharacteristicWriteType = controlChar.properties.contains(.write) ? .withResponse : .withoutResponse

            // Say what this build can take, before START rather than after. A
            // sender that reaches START without having seen this knows the far
            // side is old and refuses it with the update it needs.
            //
            // Senders up to v1.0.10 answer this with success or an ATT error
            // depending on their platform, and then carry on waiting for
            // START; neither is a failed connection. Any error lands in
            // didWriteValueFor, which this class deliberately does not
            // implement.
            let capsWriteType: CBCharacteristicWriteType = controlChar.properties.contains(.writeWithoutResponse) ? .withoutResponse : writeType
            peripheral.writeValue(Data(BTControl.capabilities().utf8), for: controlChar, type: capsWriteType)

            // Who this is, ahead of START. The sender reads the name only to
            // tell an Apple receiver from the rest; it is never listed.
            let myName = Host.current().localizedName ?? "Mac"
            peripheral.writeValue(Data(BTControl.hello(myName).utf8), for: controlChar, type: writeType)

            // Flush any control commands buffered while characteristics were resolving
            for cmd in pendingControlWrites {
                let pendingType: CBCharacteristicWriteType = controlChar.properties.contains(.write) ? .withResponse : .withoutResponse
                peripheral.writeValue(Data(cmd.utf8), for: controlChar, type: pendingType)
            }
            pendingControlWrites.removeAll()

            guard let token = expectedSessionToken, !token.isEmpty else { return }
            peripheral.writeValue(Data("START:\(token)".utf8), for: controlChar, type: writeType)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let value = characteristic.value else { return }

        if characteristic.uuid == BTServiceIDs.metadata {
            if let text = String(data: value, encoding: .utf8) {
                if let sealed = BTControl.parseApOffer(text) {
                    emit(["type": "apOffer", "sealed": sealed])
                    return
                }
                if let key = BTControl.parseKeyExchange(text) {
                    emit(["type": "peerKey", "key": key])
                    return
                }
            }
            // A link frame is not a file: the sender is negotiating the
            // Wi-Fi network the transfer will actually cross (generation 4),
            // and a serve frame says where on that network the file then is.
            if let json = try? JSONSerialization.jsonObject(with: value) as? [String: Any] {
                if let link = json["link"] as? [String: Any] {
                    emit(["type": "linkDirective", "link": link])
                    return
                }
                if let serve = json["serve"] as? [String: Any] {
                    emit(["type": "serveInfo", "serve": serve])
                    return
                }
            }
            // Anything else on this characteristic is the first frame of a file
            // from a sender that predates the direct link — or half a frame,
            // cut by a connection that carries too little.
            refuseStaleSender()
            return
        }

        if characteristic.uuid == BTServiceIDs.data, !value.isEmpty {
            // Nothing is sent here any more. Bytes are an older sender.
            refuseStaleSender()
        }
    }
}
