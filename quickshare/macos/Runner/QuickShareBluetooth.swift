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
    /// 5 — nothing derived from a session code goes on the air: the link
    /// directive carries no digits, the sealed credentials are bound to the
    /// locator in the QR, and the token and locator are random. A generation-4
    /// peer cannot take part; see `BleControlProtocol.generation` in Dart.
    static let generation = 5

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

    /// Shown when a receiver below the current generation asks for a transfer.
    /// True of every older generation, so it does not say what that build
    /// could do. Mirrors BleControlProtocol.directLinkRequiredMessage.
    static let directLinkRequiredMessage =
        "The receiving device is on an older version of DirectDrop that "
        + "cannot set up the transfer with this one. Update it, and the "
        + "transfer moves to a direct Wi-Fi link."

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

// MARK: - BEGIN QuickShareBleFrame
// The same text in ios/Runner and macos/Runner (a test holds the two to it),
// and the same format as lib/core/transfer/ble_frame.dart (a test compiles this
// and runs it against what that produces). Change all three or none.

/// How one negotiation frame crosses the metadata characteristic.
///
/// A notification carries at most what the two devices negotiated — the ATT MTU
/// less three: 182 to an iPhone, 20 to a connection nobody negotiated — and the
/// platforms cut a longer one to that and say nothing. A `link` frame with
/// sealed credentials is 203 bytes and a `serve` frame 225, so a frame is cut
/// into parts that each fit and the far side puts it back together:
///
///     byte 0   marker       0xD1 — never `{`, which bare JSON starts with
///     byte 1   frame id     every part of one frame carries the same
///     byte 2   part index   0-based, strictly increasing
///     byte 3   part count   1...255, the same in every part
///     byte 4.. payload      at least one byte
///
/// The channel is neither encrypted nor bonded, so anybody in range can write a
/// part of their own: the assembler believes nothing it is not owed. Parts must
/// arrive in order, none may repeat or be skipped, the count may not change, the
/// whole may not outgrow `maxFrameBytes`, and a frame that has begun must end
/// within `assemblyTimeout`. Anything else is an error that says which.
enum QuickShareBleFrameProblem: String {
    // The sender's, when cutting a frame up.
    case emptyFrame, frameTooLarge, notificationTooSmall, tooManyParts
    // The receiver's, when putting one together.
    case unframed, notAFrame, tooShort, badHeader, orphanPart, interrupted
    case interleaved, duplicatePart, missingPart, countChanged, tooLarge, timedOut
}

struct QuickShareBleFrameError: Error {
    let problem: QuickShareBleFrameProblem
    let message: String

    /// Whether the sender does not cut its frames into parts at all, which only
    /// a build from before the parts did. The one problem that says the other
    /// side is an older version; every other is a frame damaged on the way.
    var isOlderSender: Bool { problem == .unframed }
}

enum QuickShareBleFrame {
    static let marker: UInt8 = 0xD1
    static let headerBytes = 4
    static let maxParts = 255
    static let maxFrameBytes = 3072
    static let maxNotificationBytes = 512
    static let defaultNotificationBytes = 20
    static let assemblyTimeout: TimeInterval = 10

    /// Bare JSON starts with `{`; every sender of generation 4 and below sends
    /// it so, and no framed sender starts a notification with it.
    static func looksUnframed(_ first: UInt8) -> Bool { first == 0x7B }

    /// The parts of `frame`, each at most `notificationBytes` long.
    static func split(_ frame: Data, frameId: UInt8, notificationBytes: Int) throws -> [Data] {
        let bytes = [UInt8](frame)
        if bytes.isEmpty {
            throw QuickShareBleFrameError(problem: .emptyFrame, message: "There is no frame to send.")
        }
        if bytes.count > maxFrameBytes {
            throw QuickShareBleFrameError(
                problem: .frameTooLarge,
                message: "A \(bytes.count)-byte frame is past the \(maxFrameBytes) bytes a Bluetooth frame may have.")
        }
        let payload = notificationBytes - headerBytes
        if payload < 1 {
            throw QuickShareBleFrameError(
                problem: .notificationTooSmall,
                message: "A Bluetooth notification of \(notificationBytes) bytes cannot carry a part of a frame: the header alone is \(headerBytes).")
        }
        let count = (bytes.count + payload - 1) / payload
        if count > maxParts {
            throw QuickShareBleFrameError(
                problem: .tooManyParts,
                message: "A \(bytes.count)-byte frame needs \(count) parts of \(payload) bytes at \(notificationBytes) bytes a notification, and a frame may have \(maxParts).")
        }
        var parts: [Data] = []
        for index in 0..<count {
            let from = index * payload
            let to = min(from + payload, bytes.count)
            var part = Data([marker, frameId, UInt8(index), UInt8(count)])
            part.append(contentsOf: bytes[from..<to])
            parts.append(part)
        }
        return parts
    }
}

/// Puts the parts of a frame back together. One per connection.
///
/// Pure: it keeps no clock. The owner starts one when `isAssembling` turns true
/// and calls `expire()` when it runs out, so the same code runs under a test.
///
/// A fault is final until `reset()`: once one part is missing, repeated or not
/// ours, the parts after it say nothing a receiver can believe, and taking each
/// as a new fault would bury the first. Further parts are ignored.
struct QuickShareBleFrameAssembler {
    enum Step {
        /// The part was taken; the frame is not finished.
        case need
        /// The frame is whole.
        case frame(Data)
    }

    let maxFrameBytes: Int
    private(set) var isAssembling = false
    private(set) var hasFaulted = false
    private var id: UInt8 = 0
    private var count = 0
    private var next = 0
    private var bytes: [UInt8] = []

    init(maxFrameBytes: Int = QuickShareBleFrame.maxFrameBytes) {
        self.maxFrameBytes = maxFrameBytes
    }

    /// Takes one notification. Throws what is wrong with it, leaving the
    /// assembler empty and ready for the next frame.
    mutating func accept(_ data: Data) throws -> Step {
        if hasFaulted { return .need }
        let part = [UInt8](data)
        guard let first = part.first else {
            throw fault(.tooShort, "An empty notification arrived on the frame channel.")
        }
        if first != QuickShareBleFrame.marker {
            if !isAssembling && QuickShareBleFrame.looksUnframed(first) {
                throw fault(.unframed, "A \(part.count)-byte notification of bare JSON arrived: the sender does not cut its frames into parts.")
            }
            throw fault(.notAFrame, "A \(part.count)-byte notification that is not a part of a frame (it starts with 0x\(String(first, radix: 16))).")
        }
        if part.count <= QuickShareBleFrame.headerBytes {
            throw fault(.tooShort, "A \(part.count)-byte part has a header and nothing after it.")
        }

        let partId = part[1]
        let index = Int(part[2])
        let partCount = Int(part[3])
        if partCount == 0 || index >= partCount {
            throw fault(.badHeader, "A part says it is number \(index) of \(partCount).")
        }

        if !isAssembling {
            if index != 0 {
                throw fault(.orphanPart, "Part \(index) of \(partCount) of frame \(partId) arrived with no beginning: the earlier parts were lost, or this is not from the sender.")
            }
            isAssembling = true
            id = partId
            count = partCount
            next = 0
            bytes = []
        } else {
            if partId != id {
                if index == 0 {
                    throw fault(.interrupted, "Frame \(partId) began while frame \(id) had \(next) of \(count) parts.")
                }
                throw fault(.interleaved, "Part \(index) of frame \(partId) arrived inside frame \(id).")
            }
            if partCount != count {
                throw fault(.countChanged, "Frame \(id) said it had \(count) parts, and then part \(index) said \(partCount).")
            }
            if index < next {
                throw fault(.duplicatePart, "Part \(index) of frame \(id) arrived twice.")
            }
            if index > next {
                throw fault(.missingPart, "Part \(index) of frame \(id) arrived with part \(next) still missing: a part was lost.")
            }
        }

        let payload = part.count - QuickShareBleFrame.headerBytes
        if bytes.count + payload > maxFrameBytes {
            throw fault(.tooLarge, "Frame \(id) is past \(maxFrameBytes) bytes at part \(index) of \(count).")
        }
        bytes.append(contentsOf: part[QuickShareBleFrame.headerBytes...])
        next = index + 1

        if next == count {
            let frame = Data(bytes)
            clear()
            return .frame(frame)
        }
        return .need
    }

    /// The frame in progress has run out of time. Nil when none is.
    mutating func expire() -> QuickShareBleFrameError? {
        guard isAssembling else { return nil }
        let error = QuickShareBleFrameError(
            problem: .timedOut,
            message: "Frame \(id) did not finish: \(next) of \(count) parts arrived in \(Int(QuickShareBleFrame.assemblyTimeout)) seconds.")
        clear()
        hasFaulted = true
        return error
    }

    /// Forgets a frame in progress and takes back the last fault: the next part
    /// is the first of a new stream. Nothing is reported. For a new connection.
    mutating func reset() {
        clear()
        hasFaulted = false
    }

    private mutating func clear() {
        isAssembling = false
        id = 0
        count = 0
        next = 0
        bytes = []
    }

    private mutating func fault(_ problem: QuickShareBleFrameProblem, _ message: String) -> QuickShareBleFrameError {
        clear()
        hasFaulted = true
        return QuickShareBleFrameError(problem: problem, message: message)
    }
}
// MARK: - END QuickShareBleFrame

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
    private var expectedLocator: String?
    private var centralConnectTimeoutTimer: Timer?

    /// A sender that is pushing a file over this channel is an older build.
    /// Said once: its file is thousands of notifications.
    private var reportedStaleSender = false

    // MARK: Frames

    /// A part of a frame waiting for the radio.
    private struct OutgoingPart {
        let data: Data
        /// The Flutter call to answer once this part has gone. Only the last part of
        /// a frame carries it, so a frame is "sent" when all of it has been.
        let finishes: FlutterResult?
    }

    private var outbox: [OutgoingPart] = []
    private var outboxWatchdog: Timer?
    private var metadataCentrals: [UUID: CBCentral] = [:]
    private var nextFrameId = UInt8.random(in: 0...255)

    private var frames = QuickShareBleFrameAssembler()
    private var frameClock: Timer?
    private var reportedDamagedFrame = false

    /// Cuts `frame` into parts that fit what the subscribed receiver can take, and
    /// sends them in order. Answers `result` when the last has gone to the radio,
    /// or with why it could not.
    ///
    /// Sent whole is not an option: a notification carries the central's
    /// `maximumUpdateValueLength` (182 to an iPhone) and a frame that is longer is
    /// cut by CoreBluetooth without a word.
    private func sendFrame(_ frame: Data, _ result: @escaping FlutterResult) {
        guard peripheralManager != nil, metadataChar != nil else {
            result(FlutterError(code: "UNAVAILABLE", message: "no link channel is up", details: nil))
            return
        }
        guard !metadataCentrals.isEmpty else {
            result(FlutterError(code: "UNAVAILABLE", message: "the receiver is not subscribed to the frame channel", details: nil))
            return
        }
        let parts: [Data]
        do {
            parts = try QuickShareBleFrame.split(
                frame, frameId: nextFrameId, notificationBytes: notificationBytes())
        } catch let error as QuickShareBleFrameError {
            result(FlutterError(code: "FRAME", message: error.message, details: error.problem.rawValue))
            return
        } catch {
            result(FlutterError(code: "FRAME", message: "\(error)", details: nil))
            return
        }
        nextFrameId = nextFrameId &+ 1
        for (index, part) in parts.enumerated() {
            outbox.append(OutgoingPart(data: part, finishes: index == parts.count - 1 ? result : nil))
        }
        drainOutbox()
    }

    /// The most one notification can carry to every receiver subscribed: the least
    /// of their limits, or what a connection nobody negotiated carries.
    private func notificationBytes() -> Int {
        let carried = metadataCentrals.values.map { $0.maximumUpdateValueLength }.filter { $0 > 0 }
        guard let least = carried.min() else { return QuickShareBleFrame.defaultNotificationBytes }
        return min(least, QuickShareBleFrame.maxNotificationBytes)
    }

    /// Hands the radio as many waiting parts as it will take, in order.
    ///
    /// `updateValue` answers false when the transmit queue is full. That part was
    /// not sent and nothing behind it may be: it and every part after it stay where
    /// they are, and `peripheralManagerIsReady` is what says to go on. Parts are
    /// never skipped, repeated or reordered, which is the whole of what the
    /// receiver checks.
    private func drainOutbox() {
        guard let manager = peripheralManager, let metadata = metadataChar else {
            failOutbox(code: "UNAVAILABLE", message: "the link channel went away before the frame was sent")
            return
        }
        while let first = outbox.first {
            if !manager.updateValue(first.data, for: metadata, onSubscribedCentrals: nil) {
                armOutboxWatchdog()
                return
            }
            outbox.removeFirst()
            outboxWatchdog?.invalidate()
            outboxWatchdog = nil
            first.finishes?(nil)
        }
    }

    /// A radio that stays busy for ten seconds is a connection that has gone: the
    /// frames waiting are answered with an error instead of for ever.
    private func armOutboxWatchdog() {
        guard outboxWatchdog == nil else { return }
        outboxWatchdog = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            self?.outboxWatchdog = nil
            self?.failOutbox(code: "TIMEOUT", message: "the radio stayed busy for 10 seconds and the frame could not be sent")
        }
    }

    /// Answers every frame still waiting with an error and forgets its parts. A
    /// frame that went out half-way is left to the receiver, whose assembler
    /// reports it.
    private func failOutbox(code: String, message: String) {
        outboxWatchdog?.invalidate()
        outboxWatchdog = nil
        let waiting = outbox
        outbox.removeAll()
        for part in waiting {
            part.finishes?(FlutterError(code: code, message: message, details: nil))
        }
    }

    /// One notification from the sender's metadata characteristic.
    private func acceptFramePart(_ part: Data) {
        // After one frame has been refused the rest of the connection is not to be
        // believed, and reporting each part that follows would bury the first.
        if reportedStaleSender || reportedDamagedFrame { return }
        do {
            switch try frames.accept(part) {
            case .need:
                armFrameClock()
            case .frame(let frame):
                disarmFrameClock()
                handleFrame(frame)
            }
        } catch let fault as QuickShareBleFrameError {
            disarmFrameClock()
            refuseFrame(fault)
        } catch {
            disarmFrameClock()
            refuseDamagedFrame("\(error)")
        }
    }

    /// A frame that has begun has ten seconds, counted from its first part.
    private func armFrameClock() {
        guard frames.isAssembling, frameClock == nil else { return }
        frameClock = Timer.scheduledTimer(withTimeInterval: QuickShareBleFrame.assemblyTimeout, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.frameClock = nil
            if let fault = self.frames.expire() { self.refuseFrame(fault) }
        }
    }

    private func disarmFrameClock() {
        frameClock?.invalidate()
        frameClock = nil
    }

    private func resetFrames() {
        frames.reset()
        disarmFrameClock()
        reportedDamagedFrame = false
    }

    /// A whole frame. A link frame is not a file: the sender is negotiating the
    /// Wi-Fi network the transfer will cross, and a serve frame says where on it the
    /// file then is.
    private func handleFrame(_ frame: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: frame) as? [String: Any] else {
            refuseDamagedFrame("A frame of \(frame.count) bytes arrived complete but is not a JSON object.")
            return
        }
        if let link = json["link"] as? [String: Any] {
            emit(["type": "linkDirective", "link": link])
            return
        }
        if let serve = json["serve"] as? [String: Any] {
            emit(["type": "serveInfo", "serve": serve])
            return
        }
        refuseDamagedFrame("A frame of \(frame.count) bytes arrived complete but is neither a link nor a serve frame.")
    }

    /// "An older version" is said when the sender's frames are not cut into parts
    /// at all, which only a build from before the parts did. A part missing,
    /// repeated, foreign or late is a connection having a bad time, or somebody
    /// else's write, and updating would not help.
    private func refuseFrame(_ fault: QuickShareBleFrameError) {
        if fault.isOlderSender {
            refuseStaleSender()
        } else {
            refuseDamagedFrame(fault.message)
        }
    }

    /// A frame that could not be put together or read, which says nothing about the
    /// sender's version. Said once.
    private func refuseDamagedFrame(_ why: String) {
        guard !reportedDamagedFrame else { return }
        reportedDamagedFrame = true
        emit(["type": "receiverFailed",
              "error": "A message from the sending device was lost or damaged on the way, so the transfer could not be set up. \(why)",
              "code": "bluetoothTransferFailed"])
    }

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
                             locator: args["locator"] as? String)
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
            // Cut into parts that fit the receiver and sent in order, however
            // often the radio has to be waited for; answered when the last has
            // gone. See sendFrame.
            sendFrame(data, result)

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
                          locator: scanArgs?["locator"] as? String)
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

    private func startAdvertising(sessionToken: String?, locator: String? = nil) {
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
        // The session's locator: random, drawn for this session, the same one
        // the QR carries, and related to no code and no token. It only lets a
        // receiver that scanned the QR pick this device out of several. Never
        // anything derived from a session code: that can be searched for the
        // code by anyone in range.
        if let locator, !locator.isEmpty {
            pendingDeviceName = "QuickShare-\(locator)"
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
        failOutbox(code: "UNAVAILABLE", message: "the link channel was closed before the frame was sent")
        metadataCentrals.removeAll()
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

    private func startScanning(sessionToken: String? = nil, locator: String? = nil) {
        discovered.removeAll()
        expectedSessionToken = sessionToken
        expectedLocator = locator
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
        resetFrames()
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
        resetFrames()
    }

    /// A sender that writes a file's metadata or bytes to this channel is a
    /// build from before the direct link. It is told so, once, in words the
    /// person can act on; nothing it sends is written anywhere.
    private func refuseStaleSender() {
        guard !reportedStaleSender else { return }
        reportedStaleSender = true
        emit(["type": "receiverFailed",
              "error": "The sending device is on an older version of DirectDrop that cannot set up the transfer with this one. "
                  + "Update the sending device and scan its new code.",
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
            metadataCentrals[central.identifier] = central
        }
        if characteristic.uuid == BTServiceIDs.data {
            subscribedToData = true
        }
        emit(["type": "centralConnected"])
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        if characteristic.uuid == BTServiceIDs.metadata {
            metadataCentrals.removeValue(forKey: central.identifier)
            subscribedToMetadata = !metadataCentrals.isEmpty
            if metadataCentrals.isEmpty {
                failOutbox(code: "UNAVAILABLE", message: "the receiver stopped listening before the frame was sent")
            }
        }
        if characteristic.uuid == BTServiceIDs.data {
            subscribedToData = false
        }
    }

    /// The transmit queue has room again: the parts that were refused go next,
    /// in the order they were refused.
    public func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        drainOutbox()
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
        // What a sender advertises is the session's locator: random, the one
        // the QR carries, and related to no code. A device with no
        // `QuickShare-` name at all — a Windows PC or an Android phone, which
        // cannot carry one beside the service UUID — is accepted: the scan is
        // already filtered to our service, and the START token is what
        // authenticates. Earlier builds advertised the first eight characters
        // of the token instead, so that match stays as the fallback —
        // dropping it would make this build unable to see them.
        if advertisedName.hasPrefix("QuickShare-") {
            if let expectedLocator, !expectedLocator.isEmpty {
                if !advertisedName.contains(expectedLocator) { return }
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
        resetFrames()

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
            // Every notification here is a part of a frame (or something that
            // should not be): the assembler hands back whole frames and says
            // what is wrong with the rest.
            acceptFramePart(value)
            return
        }

        if characteristic.uuid == BTServiceIDs.data, !value.isEmpty {
            // Nothing is sent here any more. Bytes are an older sender.
            refuseStaleSender()
        }
    }
}
