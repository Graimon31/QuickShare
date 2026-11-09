import Foundation
import Flutter
import CoreBluetooth
import UIKit

// MARK: - BEGIN QuickSharePairingControl
private enum QuickSharePairingControl {
  static func isValid(_ command: String) -> Bool {
    command.hasPrefix("PAIR:") && command.utf8.count <= 180
  }
}
// MARK: - END QuickSharePairingControl

/// iOS CoreBluetooth bridge for QuickShare's Bluetooth rendezvous.
///
/// The same GATT protocol is used by the macOS and iOS implementations: the
/// sender advertises a service (and a name derived from the session), the
/// receiver scans for it, subscribes to the metadata and data characteristics,
/// and writes CAPS / HELLO / `START:<token>`; Dart then negotiates a Wi-Fi
/// link over the metadata characteristic.
///
/// **No file crosses this bridge.** Since protocol generation 4 the bytes
/// travel over a Wi-Fi link the two devices raise between them, and the owner's
/// decision is that a file does not travel over plain Bluetooth at all. What
/// used to push and receive them — a notification pump on the sender, a
/// partial-file writer on the receiver — was unreachable, and is gone. The
/// data characteristic stays in the service because the receiver's
/// subscription to it is how the sender learns it is fully connected.
/// The control-characteristic vocabulary, mirrored from
/// `lib/core/transfer/ble_control_protocol.dart`. See that file for why a
/// receiver announces itself before it starts a transfer.
private enum QuickShareBleControl {
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
  /// by anyone listening, which is the point: what the two sides derive from
  /// the pair never crosses the wire.
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

private enum QuickShareBluetoothIDs {
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

public final class QuickShareBluetoothPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private var eventSink: FlutterEventSink?

  // Central (receiver) state.
  private var centralManager: CBCentralManager?
  private var discovered: [String: CBPeripheral] = [:]
  private var expectedSessionToken: String?
  private var expectedLocator: String?
  private var pairingOnly = false
  private var pairingReadyEmitted = false
  private var disconnectingPairingPeers = Set<UUID>()
  private var deferredReconnectId: String?
  private var pendingStartScan = false
  private var scanRequested = false
  private var discoveryDiagnostics = Set<String>()
  private var targetPeripheral: CBPeripheral?
  private var remoteControl: CBCharacteristic?
  private var metadataSubscribed = false
  private var dataSubscribed = false
  private var centralConnectTimeoutTimer: Timer?
  private var pairingWriteParts: [Data] = []
  private var pairingWriteResult: FlutterResult?
  private var pairingWriteTimer: Timer?
  private var pairingWriteFrameId: UInt8 = 0
  private var pairingInput: [UUID: (assembler: QuickShareBleFrameAssembler, started: Date)] = [:]

  /// A sender that is pushing a file over this channel is an older build.
  /// Said once: its file is thousands of notifications.
  private var reportedStaleSender = false

  // Peripheral (sender) state. iOS supports both central and peripheral
  // roles, so the phone can send directly to the existing macOS/iOS receiver.
  private var peripheralManager: CBPeripheralManager?
  private var pendingServiceToAdd: CBMutableService?
  private var pendingDeviceName: String?
  private var senderControl: CBMutableCharacteristic?
  private var senderMetadata: CBMutableCharacteristic?
  private var senderData: CBMutableCharacteristic?
  private var senderSessionToken: String?

  /// What the receiver said it can take, from its `CAPS:` write. Nil means it
  /// never sent one.
  private var senderPeerGeneration: Int?
  private var senderSubscribedToData = false
  private var dataCentrals = Set<UUID>()
  private var senderTransferStarted = false

  // MARK: Frames

  /// A part of a frame waiting for the radio.
  private struct OutgoingPart {
    let data: Data
    let peerId: UUID?
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
  private func sendFrame(_ frame: Data, _ result: @escaping FlutterResult, peerId: UUID? = nil) {
    guard peripheralManager != nil, senderMetadata != nil else {
      result(FlutterError(code: "UNAVAILABLE", message: "no link channel is up", details: nil))
      return
    }
    guard !metadataCentrals.isEmpty else {
      result(FlutterError(code: "UNAVAILABLE", message: "the receiver is not subscribed to the frame channel", details: nil))
      return
    }
    if let peerId, metadataCentrals[peerId] == nil {
      result(FlutterError(code: "UNAVAILABLE", message: "the pairing peer is not subscribed", details: nil))
      return
    }
    let parts: [Data]
    do {
      parts = try QuickShareBleFrame.split(
        frame, frameId: nextFrameId, notificationBytes: notificationBytes(peerId: peerId))
    } catch let error as QuickShareBleFrameError {
      result(FlutterError(code: "FRAME", message: error.message, details: error.problem.rawValue))
      return
    } catch {
      result(FlutterError(code: "FRAME", message: "\(error)", details: nil))
      return
    }
    nextFrameId = nextFrameId &+ 1
    for (index, part) in parts.enumerated() {
      outbox.append(OutgoingPart(data: part, peerId: peerId, finishes: index == parts.count - 1 ? result : nil))
    }
    drainOutbox()
  }

  /// The most one notification can carry to every receiver subscribed: the least
  /// of their limits, or what a connection nobody negotiated carries.
  private func notificationBytes(peerId: UUID? = nil) -> Int {
    let recipients = peerId.flatMap { metadataCentrals[$0] }.map { [$0] } ?? Array(metadataCentrals.values)
    let carried = recipients.map { $0.maximumUpdateValueLength }.filter { $0 > 0 }
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
    guard let manager = peripheralManager, let metadata = senderMetadata else {
      failOutbox(code: "UNAVAILABLE", message: "the link channel went away before the frame was sent")
      return
    }
    while let first = outbox.first {
      let recipients: [CBCentral]?
      if let peerId = first.peerId {
        guard let central = metadataCentrals[peerId] else {
          failOutbox(code: "UNAVAILABLE", message: "the pairing peer stopped listening")
          return
        }
        recipients = [central]
      } else {
        recipients = nil
      }
      if !manager.updateValue(first.data, for: metadata, onSubscribedCentrals: recipients) {
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
    failPairingWrite("Bluetooth pairing connection closed")
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
    if let pair = json["pair"] as? [String: Any] {
      emit(["type": "pairingFrame", "pair": pair, "deviceId": targetPeripheral?.identifier.uuidString ?? ""])
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

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = QuickShareBluetoothPlugin()
    let methods = FlutterMethodChannel(name: "quickshare/bluetooth", binaryMessenger: registrar.messenger())
    let events = FlutterEventChannel(name: "quickshare/bluetooth/events", binaryMessenger: registrar.messenger())
    events.setStreamHandler(instance)
    methods.setMethodCallHandler { call, result in
      instance.handle(call, result: result)
    }
  }

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

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "startScanning":
      let args = call.arguments as? [String: Any]
      startScanning(sessionToken: args?["sessionToken"] as? String,
                    locator: args?["locator"] as? String,
                    pairingOnly: args?["pairingOnly"] as? Bool ?? false)
      result(nil)

    case "stopScanning":
      stopScanning()
      result(nil)

    case "connect":
      guard let args = call.arguments as? [String: Any],
            let deviceId = args["deviceId"] as? String else {
        result(FlutterError(code: "BAD_ARGS", message: "deviceId required", details: nil))
        return
      }
      connect(deviceId: deviceId)
      result(nil)

    case "sendPairingCommand":
      guard let args = call.arguments as? [String: Any],
        let command = args["command"] as? String,
        QuickSharePairingControl.isValid(command) else {
        result(FlutterError(code: "BAD_ARGS", message: "invalid pairing command", details: nil))
        return
      }
      sendPairingCommand(command, result)

    case "disconnectPairing":
      disconnectPairing()
      result(nil)

    case "cancelTransfer":
      cancelTransfer()
      result(nil)

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
            let data = try? JSONSerialization.data(withJSONObject: frame) else {
        result(FlutterError(code: "BAD_ARGS", message: "frame required", details: nil))
        return
      }
      // Cut into parts that fit the receiver and sent in order, however often
      // the radio has to be waited for; answered when the last has gone. See
      // sendFrame.
      let peerId: UUID?
      if let value = args["peerId"] {
        guard let value = value as? String, let parsed = UUID(uuidString: value) else {
          result(FlutterError(code: "BAD_ARGS", message: "invalid peerId", details: nil))
          return
        }
        peerId = parsed
      } else {
        peerId = nil
      }
      sendFrame(data, result, peerId: peerId)

    // The receiver's half of the negotiation: the credentials of the network
    // it raised, written back over the control characteristic.
    case "sendApOffer":
      guard let args = call.arguments as? [String: Any],
            let sealed = args["sealed"] as? String else {
        result(FlutterError(code: "BAD_ARGS", message: "sendApOffer needs sealed credentials", details: nil))
        return
      }
      writeControl(QuickShareBleControl.apOffer(sealed), result)

    case "sendKeyExchange":
      guard let args = call.arguments as? [String: Any],
            let key = args["key"] as? String else {
        result(FlutterError(code: "BAD_ARGS", message: "sendKeyExchange needs a key", details: nil))
        return
      }
      writeControl(QuickShareBleControl.keyExchange(key), result)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private var pendingControlWrites: [String] = []

  private func startScanning(sessionToken: String?, locator: String? = nil, pairingOnly: Bool = false) {
    discovered.removeAll()
    scanRequested = true
    discoveryDiagnostics.removeAll()
    expectedSessionToken = sessionToken
    expectedLocator = locator
    self.pairingOnly = pairingOnly
    pairingReadyEmitted = false
    let manager = centralManager ?? CBCentralManager(delegate: self, queue: nil)
    centralManager = manager
    let options: [String: Any] = [CBCentralManagerScanOptionAllowDuplicatesKey: true]
    if manager.state == .poweredOn {
      emit(["type": "bleDiagnostic", "message": "scan_started service=\(QuickShareBluetoothIDs.service.uuidString)"])
      manager.scanForPeripherals(withServices: [QuickShareBluetoothIDs.service], options: options)
    } else {
      pendingStartScan = true
      centralManagerDidUpdateState(manager)
    }
  }

  private func stopScanning() {
    centralManager?.stopScan()
    pendingStartScan = false
    scanRequested = false
  }

  private func connect(deviceId: String) {
    guard let peripheral = discovered[deviceId] else {
      emit(["type": "receiverFailed", "deviceId": deviceId, "error": "Device no longer available"])
      return
    }
    centralManager?.stopScan()
    if disconnectingPairingPeers.contains(peripheral.identifier) {
      deferredReconnectId = deviceId
      centralConnectTimeoutTimer?.invalidate()
      centralConnectTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 20.0, repeats: false) { [weak self] _ in
        guard let self = self, self.deferredReconnectId == deviceId else { return }
        self.deferredReconnectId = nil
        self.centralConnectTimeoutTimer = nil
        self.emit(["type": "receiverFailed", "deviceId": deviceId, "error": "Bluetooth disconnect timed out", "code": "timeout"])
      }
      return
    }
    deferredReconnectId = nil
    targetPeripheral = peripheral
    pairingReadyEmitted = false
    metadataSubscribed = false
    dataSubscribed = false
    remoteControl = nil
    reportedStaleSender = false
    resetFrames()
    pendingControlWrites.removeAll()
    peripheral.delegate = self

    centralConnectTimeoutTimer?.invalidate()
    centralConnectTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 20.0, repeats: false) { [weak self, weak peripheral] _ in
      guard let self = self, let peripheral = peripheral,
            self.targetPeripheral === peripheral else { return }
      self.centralConnectTimeoutTimer = nil
      self.targetPeripheral = nil
      self.centralManager?.cancelPeripheralConnection(peripheral)
      self.emit([
        "type": "receiverFailed",
        "deviceId": peripheral.identifier.uuidString,
            "error": "Failed to connect: Bluetooth handshake timed out",
        "code": "timeout"
      ])
    }

    centralManager?.connect(peripheral, options: nil)
  }

  /// A cancellation callback may arrive after discovery has already found the
  /// same peripheral again. Wait for it before starting the next connection.
  private func finishPairingDisconnect(_ peripheral: CBPeripheral) -> Bool {
    guard disconnectingPairingPeers.remove(peripheral.identifier) != nil else { return false }
    if deferredReconnectId == peripheral.identifier.uuidString {
      let id = deferredReconnectId!
      deferredReconnectId = nil
      connect(deviceId: id)
    }
    return true
  }

  private func disconnectPairing() {
    centralConnectTimeoutTimer?.invalidate()
    centralConnectTimeoutTimer = nil
    stopScanning()
    deferredReconnectId = nil
    let previous = targetPeripheral
    targetPeripheral = nil
    if let previous, previous.state != .disconnected {
      disconnectingPairingPeers.insert(previous.identifier)
      centralManager?.cancelPeripheralConnection(previous)
    }
    remoteControl = nil
    metadataSubscribed = false
    dataSubscribed = false
    pendingControlWrites.removeAll()
    discovered.removeAll()
    resetFrames()
    pairingOnly = false
    pairingReadyEmitted = false
  }

  private func cancelTransfer() {
    stopAdvertising()
    disconnectPairing()
  }

  // MARK: Peripheral sender

  private func startAdvertising(sessionToken: String?, locator: String? = nil) {
    stopAdvertising()
    senderSessionToken = sessionToken
    senderTransferStarted = false
    senderSubscribedToData = false
    dataCentrals.removeAll()
    senderPeerGeneration = nil

    let control = CBMutableCharacteristic(
      type: QuickShareBluetoothIDs.control,
      properties: [.write, .writeWithoutResponse],
      value: nil,
      permissions: [.writeable]
    )
    let metadataCharacteristic = CBMutableCharacteristic(
      type: QuickShareBluetoothIDs.metadata,
      properties: [.notify],
      value: nil,
      permissions: [.readable]
    )
    let data = CBMutableCharacteristic(
      type: QuickShareBluetoothIDs.data,
      properties: [.notify],
      value: nil,
      permissions: [.readable]
    )
    senderControl = control
    senderMetadata = metadataCharacteristic
    senderData = data

    let service = CBMutableService(type: QuickShareBluetoothIDs.service, primary: true)
    service.characteristics = [control, metadataCharacteristic, data]
    pendingServiceToAdd = service
    // The session's locator: random, drawn for this session, the same one the
    // QR carries, and related to no code and no token. It only lets a receiver
    // that scanned the QR pick this device out of several. Never anything
    // derived from a session code (anyone in range can search that for the
    // code), and never a slice of the token, which is what every earlier build
    // fell back to and which puts eight characters of the session's secret in
    // a packet anyone in range can read.
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

  private func stopAdvertising() {
    failOutbox(code: "UNAVAILABLE", message: "the link channel was closed before the frame was sent")
    metadataCentrals.removeAll()
    pairingInput.removeAll()
    peripheralManager?.stopAdvertising()
    peripheralManager?.removeAllServices()
    peripheralManager = nil
    pendingServiceToAdd = nil
    pendingDeviceName = nil
    senderControl = nil
    senderMetadata = nil
    senderData = nil
    senderSubscribedToData = false
    dataCentrals.removeAll()
    senderTransferStarted = false
    senderSessionToken = nil
    senderPeerGeneration = nil
  }

  private func beginSenderTransferIfReady() {
    guard !senderTransferStarted, senderMetadata != nil else { return }

    // Generation 4 is where the bytes left this radio. A peer from this
    // generation on gets the Wi-Fi link negotiated over this channel — Dart
    // runs that from the receiverReady event. A peer below it gets told to
    // update rather than sent anything.
    let peerGen = senderPeerGeneration ?? QuickShareBleControl.generation
    if peerGen >= QuickShareBleControl.generation {
      senderTransferStarted = true
      emit(["type": "receiverReady"])
    } else {
      guard senderSubscribedToData else { return }
      senderTransferStarted = true
      // The error text is English, for the log; the code is what the Dart
      // side translates for the screen.
      emit(["type": "senderFailed",
            "error": QuickShareBleControl.directLinkRequiredMessage,
            "code": "receiverTooOldForDirectLink"])
    }
  }

  /// Writes one control command to the sender this device is connected to.
  /// Pairing writes are serialized with responses; every part must be accepted
  /// before the next, including when a peer negotiated only the minimum MTU.
  private func sendPairingCommand(_ command: String, _ result: @escaping FlutterResult) {
    guard pairingOnly, let peripheral = targetPeripheral,
      let control = remoteControl, metadataSubscribed, dataSubscribed,
      control.properties.contains(.write) else {
      result(FlutterError(code: "UNAVAILABLE", message: "pairing channel is not ready", details: nil))
      return
    }
    guard pairingWriteResult == nil else {
      result(FlutterError(code: "PAIRING_WRITE_IN_PROGRESS", message: "a pairing command is already being sent", details: nil))
      return
    }
    do {
      pairingWriteParts = try QuickShareBleFrame.split(Data(command.utf8),
        frameId: pairingWriteFrameId,
        notificationBytes: peripheral.maximumWriteValueLength(for: .withResponse))
    } catch {
      result(FlutterError(code: "FRAME", message: "pairing command cannot be framed", details: nil))
      return
    }
    pairingWriteFrameId = pairingWriteFrameId &+ 1
    pairingWriteResult = result
    pairingWriteTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
      self?.failPairingWrite("Bluetooth pairing write timed out")
    }
    peripheral.writeValue(pairingWriteParts.removeFirst(), for: control, type: .withResponse)
  }

  private func failPairingWrite(_ message: String) {
    pairingWriteTimer?.invalidate()
    pairingWriteTimer = nil
    pairingWriteParts.removeAll()
    let result = pairingWriteResult
    pairingWriteResult = nil
    result?(FlutterError(code: "UNAVAILABLE", message: message, details: nil))
  }

  /// Control frames are per central and bounded independently of metadata.
  private func pairingCommandPart(_ data: Data, from peer: UUID) -> (accepted: Bool, command: String?) {
    let now = Date()
    pairingInput = pairingInput.filter { now.timeIntervalSince($0.value.started) < QuickShareBleFrame.assemblyTimeout }
    if pairingInput[peer] == nil && pairingInput.count >= 16 { return (false, nil) }
    var state = pairingInput[peer] ?? (assembler: QuickShareBleFrameAssembler(maxFrameBytes: 180), started: now)
    do {
      switch try state.assembler.accept(data) {
      case .need:
        pairingInput[peer] = state
        return (true, nil)
      case .frame(let bytes):
        pairingInput.removeValue(forKey: peer)
        guard let command = String(data: bytes, encoding: .utf8), QuickSharePairingControl.isValid(command) else { return (false, nil) }
        return (true, command)
      }
    } catch {
      pairingInput.removeValue(forKey: peer)
      return (false, nil)
    }
  }

  private func writeControl(_ command: String, _ result: @escaping FlutterResult) {
    guard let peripheral = targetPeripheral else {
      result(FlutterError(code: "UNAVAILABLE", message: "no sender is connected", details: nil))
      return
    }
    guard let control = remoteControl, metadataSubscribed, dataSubscribed else {
      pendingControlWrites.append(command)
      result(nil)
      return
    }
    let type: CBCharacteristicWriteType =
      control.properties.contains(.write) ? .withResponse : .withoutResponse
    peripheral.writeValue(Data(command.utf8), for: control, type: type)
    result(nil)
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

extension QuickShareBluetoothPlugin: CBCentralManagerDelegate {
  public func centralManagerDidUpdateState(_ central: CBCentralManager) {
    emit(["type": "bleDiagnostic", "message": "central_state=\(central.state.rawValue) scan_requested=\(scanRequested)"])
    guard scanRequested else { return }
    if central.state == .poweredOn, pendingStartScan {
      pendingStartScan = false
      emit(["type": "bleDiagnostic", "message": "scan_started service=\(QuickShareBluetoothIDs.service.uuidString)"])
      central.scanForPeripherals(withServices: [QuickShareBluetoothIDs.service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    } else if central.state == .poweredOff || central.state == .unauthorized || central.state == .unsupported {
      pendingStartScan = false
      scanRequested = false
      let reason = central.state == .poweredOff ? "Bluetooth is turned off" : "Bluetooth is not available or not authorized"
      emit(["type": "receiverFailed", "error": reason])
    }
  }

  public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
    let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "Unknown device"
    let serviceIds = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []).map { $0.uuidString }.joined(separator: ",")
    let overflowIds = (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? []).map { $0.uuidString }.joined(separator: ",")
    let expectedPublicName = expectedLocator.map { "QuickShare-\($0)" } ?? ""
    let nameSource = advertisementData[CBAdvertisementDataLocalNameKey] == nil ? "cached-or-missing" : "advertisement"
    let publicName = !name.isEmpty && !expectedPublicName.isEmpty && expectedPublicName.hasPrefix(name) ? name : "<other-or-missing>"
    let reason: String
    if !pairingOnly, name.hasPrefix("QuickShare-"), let expectedLocator, !expectedLocator.isEmpty, !name.contains(expectedLocator) {
      reason = "locator_mismatch"
    } else if !pairingOnly, name.hasPrefix("QuickShare-"), (expectedLocator == nil || expectedLocator?.isEmpty == true), let expectedSessionToken, !name.contains(String(expectedSessionToken.prefix(8))) {
      reason = "legacy_mismatch"
    } else {
      reason = "accepted"
    }
    let diagnosticKey = "\(peripheral.identifier.uuidString)|\(publicName)|\(serviceIds)|\(overflowIds)|\(reason)"
    if discoveryDiagnostics.insert(diagnosticKey).inserted {
      emit(["type": "bleDiagnostic", "message": "discovery name=\(publicName) name_source=\(nameSource) services=\(serviceIds) overflow=\(overflowIds) filter=\(reason)"])
    }
    // What a sender advertises is the session's locator: random, the one the
    // QR carries, and related to no code. A device with no
    // `QuickShare-` name at all — a Windows PC or an Android phone, which
    // cannot carry one beside the service UUID — is accepted: the scan is
    // already filtered to our service, and the START token is what
    // authenticates. Earlier builds advertised the first eight characters of
    // the token instead, so that match stays as the fallback — dropping it
    // would make this build unable to see them.
    if !pairingOnly, name.hasPrefix("QuickShare-") {
      if let expectedLocator, !expectedLocator.isEmpty {
        if !name.contains(expectedLocator) { return }
      } else if let expectedSessionToken,
                !name.contains(String(expectedSessionToken.prefix(8))) {
        return
      }
    }
    let id = peripheral.identifier.uuidString
    if discovered[id] == nil {
      discovered[id] = peripheral
      emit(["type": "deviceDiscovered", "id": id, "name": name])
    }
  }

  public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    guard peripheral === targetPeripheral else { return }
    peripheral.discoverServices([QuickShareBluetoothIDs.service])
  }

  public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    if finishPairingDisconnect(peripheral) { return }
    guard peripheral === targetPeripheral else { return }
    centralConnectTimeoutTimer?.invalidate()
    centralConnectTimeoutTimer = nil
    var code = "connectFailed"
    if let nsError = error as NSError?, nsError.domain == CBErrorDomain, nsError.code == 14 {
      code = "peerRemovedPairingInformation"
    }
    emit([
      "type": "receiverFailed",
      "deviceId": peripheral.identifier.uuidString,
            "error": "Failed to connect: \(error?.localizedDescription ?? "unknown error")",
      "code": code
    ])
  }

  public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
    if finishPairingDisconnect(peripheral) { return }
    guard peripheral === targetPeripheral else { return }
    centralConnectTimeoutTimer?.invalidate()
    centralConnectTimeoutTimer = nil
    targetPeripheral = nil
    remoteControl = nil
    metadataSubscribed = false
    dataSubscribed = false
    pendingControlWrites.removeAll()
    discovered.removeAll()
    resetFrames()

    // Whether this matters is Dart's call: before the serve frame it ends the
    // session, after it nothing is waiting on the radio.
    emit(["type": "receiverDisconnected"])
  }
}

extension QuickShareBluetoothPlugin: CBPeripheralManagerDelegate {
  public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
    guard peripheral === peripheralManager else { return }
    emit(["type": "bleDiagnostic", "message": "peripheral_state=\(peripheral.state.rawValue)"])
    guard peripheral.state == .poweredOn else {
      if peripheral.state == .poweredOff || peripheral.state == .unauthorized || peripheral.state == .unsupported {
        let reason = peripheral.state == .poweredOff ? "Bluetooth is turned off" : "Bluetooth is not available or not authorized"
        emit(["type": "senderFailed", "error": reason])
      }
      return
    }

    if let service = pendingServiceToAdd {
      pendingServiceToAdd = nil
      peripheral.add(service)
    }
  }

  public func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
    guard peripheral === peripheralManager, pendingDeviceName != nil else { return }
    if let error {
      emit(["type": "senderFailed", "error": "Failed to publish BLE service: \(error.localizedDescription)"])
      return
    }

    peripheral.startAdvertising([
      CBAdvertisementDataServiceUUIDsKey: [QuickShareBluetoothIDs.service],
      CBAdvertisementDataLocalNameKey: pendingDeviceName ?? "QuickShare",
    ])
  }

  public func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
    guard peripheral === peripheralManager, pendingDeviceName != nil else { return }
    if let error {
      emit(["type": "bleDiagnostic", "message": "advertising_failed=\(error.localizedDescription)"])
      emit(["type": "senderFailed", "error": "Failed to start Bluetooth advertising: \(error.localizedDescription)"])
    } else {
      emit(["type": "bleDiagnostic", "message": "advertising_started service=\(QuickShareBluetoothIDs.service.uuidString) name=\(pendingDeviceName ?? "<missing>")"])
      emit(["type": "advertisingStarted"])
    }
  }

  public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
    if characteristic.uuid == QuickShareBluetoothIDs.metadata {
      metadataCentrals[central.identifier] = central
    }
    guard characteristic.uuid == QuickShareBluetoothIDs.data else { return }
    dataCentrals.insert(central.identifier)
    senderSubscribedToData = true
    emit(["type": "centralConnected"])
  }

  public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
    if characteristic.uuid == QuickShareBluetoothIDs.metadata {
      metadataCentrals.removeValue(forKey: central.identifier)
      if metadataCentrals.isEmpty || outbox.contains(where: { $0.peerId == central.identifier }) {
        failOutbox(code: "UNAVAILABLE", message: "the receiver stopped listening before the frame was sent")
      }
    }
    if characteristic.uuid == QuickShareBluetoothIDs.data {
      pairingInput.removeValue(forKey: central.identifier)
      dataCentrals.remove(central.identifier)
      senderSubscribedToData = !dataCentrals.isEmpty
      if dataCentrals.isEmpty && !senderTransferStarted {
        emit(["type": "pairingDisconnected"])
      }
    }
  }

  /// The transmit queue has room again: the parts that were refused go next, in
  /// the order they were refused.
  public func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
    drainOutbox()
  }

  public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
    for request in requests {
      let command = request.value.flatMap { String(data: $0, encoding: .utf8) }

      guard request.characteristic.uuid == QuickShareBluetoothIDs.control else {
        peripheral.respond(to: request, withResult: .requestNotSupported)
        continue
      }

      if let data = request.value, data.first == QuickShareBleFrame.marker {
        let part = pairingCommandPart(data, from: request.central.identifier)
        peripheral.respond(to: request, withResult: part.accepted ? .success : .requestNotSupported)
        if let command = part.command {
          emit(["type": "pairingCommand", "command": command, "peerId": request.central.identifier.uuidString])
        }
        continue
      }

      if let command, command.hasPrefix("PAIR:") {
        pairingInput.removeValue(forKey: request.central.identifier)
        guard QuickSharePairingControl.isValid(command) else {
          peripheral.respond(to: request, withResult: .invalidAttributeValueLength)
          continue
        }
        peripheral.respond(to: request, withResult: .success)
        emit(["type": "pairingCommand", "command": command, "peerId": request.central.identifier.uuidString])
        continue
      }

      // Always ahead of START, so it is on record before the decision about
      // what this session may do is taken.
      if let command, let generation = QuickShareBleControl.parseCapabilities(command) {
        senderPeerGeneration = generation
        peripheral.respond(to: request, withResult: .success)
        continue
      }

      // The name a receiver gives itself, written ahead of its START. Dart
      // reads it only to tell an Apple receiver from the rest; nothing is
      // listed and nothing starts because of it.
      if let name = QuickShareBleControl.parseHello(command) {
        if senderPeerGeneration == nil {
          senderPeerGeneration = QuickShareBleControl.generation
        }
        peripheral.respond(to: request, withResult: .success)
        emit(["type": "receiverAnnounced", "name": name])
        continue
      }

      // A receiver that raised the network itself says where. What is inside
      // is sealed; opening it is the coordinator's business in Dart.
      if let sealed = QuickShareBleControl.parseApOffer(command) {
        peripheral.respond(to: request, withResult: .success)
        emit(["type": "apOffer", "sealed": sealed])
        continue
      }

      // The far side's public half for the negotiation.
      if let key = QuickShareBleControl.parseKeyExchange(command) {
        peripheral.respond(to: request, withResult: .success)
        emit(["type": "peerKey", "key": key])
        continue
      }

      if QuickShareBleControl.isStart(command, token: senderSessionToken) {
        peripheral.respond(to: request, withResult: .success)
        beginSenderTransferIfReady()
      } else if QuickShareBleControl.isUnauthorizedStart(command, token: senderSessionToken) {
        // A START without the session token — a receiver too old to pair
        // securely. Refuse the write and say why, rather than leaving both
        // sides waiting on a transfer that will never begin.
        peripheral.respond(to: request, withResult: .insufficientAuthentication)
        emit(["type": "senderFailed",
              "error": QuickShareBleControl.staleReceiverMessage,
              "code": "receiverTooOldToPair"])
      } else {
        peripheral.respond(to: request, withResult: .requestNotSupported)
      }
    }
  }
}

extension QuickShareBluetoothPlugin: CBPeripheralDelegate {
  public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    guard peripheral === targetPeripheral else { return }
    if let error = error {
      centralConnectTimeoutTimer?.invalidate()
      centralConnectTimeoutTimer = nil
      emit(["type": "receiverFailed", "deviceId": peripheral.identifier.uuidString, "error": "Service discovery failed: \(error.localizedDescription)"])
      return
    }
    guard let service = peripheral.services?.first(where: { $0.uuid == QuickShareBluetoothIDs.service }) else {
      centralConnectTimeoutTimer?.invalidate()
      centralConnectTimeoutTimer = nil
      emit(["type": "receiverFailed", "deviceId": peripheral.identifier.uuidString, "error": "QuickShare service not found on device"])
      return
    }
    peripheral.discoverCharacteristics(
      [QuickShareBluetoothIDs.control, QuickShareBluetoothIDs.metadata, QuickShareBluetoothIDs.data],
      for: service
    )
  }

  public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    guard peripheral === targetPeripheral else { return }
    if let error = error {
      centralConnectTimeoutTimer?.invalidate()
      centralConnectTimeoutTimer = nil
      emit(["type": "receiverFailed", "deviceId": peripheral.identifier.uuidString, "error": "Characteristic discovery failed: \(error.localizedDescription)"])
      return
    }
    guard let characteristics = service.characteristics else {
      centralConnectTimeoutTimer?.invalidate()
      centralConnectTimeoutTimer = nil
      emit(["type": "receiverFailed", "deviceId": peripheral.identifier.uuidString, "error": "No characteristics found on device"])
      return
    }
    for characteristic in characteristics {
      switch characteristic.uuid {
      case QuickShareBluetoothIDs.control:
        remoteControl = characteristic
      case QuickShareBluetoothIDs.metadata:
        peripheral.setNotifyValue(true, for: characteristic)
      case QuickShareBluetoothIDs.data:
        peripheral.setNotifyValue(true, for: characteristic)
      default:
        break
      }
    }
  }

  public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
    guard peripheral === targetPeripheral else { return }
    if let error = error {
      centralConnectTimeoutTimer?.invalidate()
      centralConnectTimeoutTimer = nil
      emit(["type": "receiverFailed", "deviceId": peripheral.identifier.uuidString, "error": "Failed to subscribe to notifications: \(error.localizedDescription)"])
      return
    }
    if characteristic.uuid == QuickShareBluetoothIDs.metadata { metadataSubscribed = true }
    if characteristic.uuid == QuickShareBluetoothIDs.data { dataSubscribed = true }
    guard metadataSubscribed, dataSubscribed, let control = remoteControl else { return }
    if pairingOnly {
      guard !pairingReadyEmitted else { return }
      pairingReadyEmitted = true
      centralConnectTimeoutTimer?.invalidate()
      centralConnectTimeoutTimer = nil
      for command in pendingControlWrites {
        let type: CBCharacteristicWriteType = control.properties.contains(.write) ? .withResponse : .withoutResponse
        peripheral.writeValue(Data(command.utf8), for: control, type: type)
      }
      pendingControlWrites.removeAll()
      emit(["type": "pairingReady", "deviceId": peripheral.identifier.uuidString])
      return
    }
    let writeType: CBCharacteristicWriteType = control.properties.contains(.write) ? .withResponse : .withoutResponse

    // Say what this build can take, before START rather than after. A sender
    // that reaches START without having seen this knows the far side is old
    // and refuses it with the update it needs.
    //
    // Senders up to v1.0.10 answer this with an ATT error, which is not a
    // failed connection: it is an older sender behaving exactly as it always
    // did. The error lands in didWriteValueFor, which this class deliberately
    // does not implement.
    let capsWriteType: CBCharacteristicWriteType = control.properties.contains(.writeWithoutResponse) ? .withoutResponse : writeType
    peripheral.writeValue(Data(QuickShareBleControl.capabilities().utf8), for: control, type: capsWriteType)

    // Who this is, ahead of START. The sender reads the name only to tell an
    // Apple receiver from the rest; it is never listed.
    peripheral.writeValue(
      Data(QuickShareBleControl.hello(UIDevice.current.name).utf8),
      for: control, type: writeType)

    // Flush any control commands buffered while characteristics were resolving
    for cmd in pendingControlWrites {
      let pendingType: CBCharacteristicWriteType = control.properties.contains(.write) ? .withResponse : .withoutResponse
      peripheral.writeValue(Data(cmd.utf8), for: control, type: pendingType)
    }
    pendingControlWrites.removeAll()

    guard let token = expectedSessionToken, !token.isEmpty else { return }
    peripheral.writeValue(Data("START:\(token)".utf8), for: control, type: writeType)
    centralConnectTimeoutTimer?.invalidate()
    centralConnectTimeoutTimer = nil
  }

  public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
    guard peripheral === targetPeripheral, characteristic.uuid == QuickShareBluetoothIDs.control,
      pairingWriteResult != nil else { return }
    if let error {
      failPairingWrite("Bluetooth pairing write failed: \(error.localizedDescription)")
      return
    }
    if !pairingWriteParts.isEmpty {
      peripheral.writeValue(pairingWriteParts.removeFirst(), for: characteristic, type: .withResponse)
    } else {
      pairingWriteTimer?.invalidate()
      pairingWriteTimer = nil
      let result = pairingWriteResult
      pairingWriteResult = nil
      result?(nil)
    }
  }

  public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
    guard peripheral === targetPeripheral else { return }
    if let error {
      emit(["type": "receiverFailed", "deviceId": peripheral.identifier.uuidString, "error": error.localizedDescription])
      return
    }
    guard let value = characteristic.value else { return }

    if characteristic.uuid == QuickShareBluetoothIDs.metadata {
      // Every notification here is a part of a frame (or something that should
      // not be): the assembler hands back whole frames and says what is wrong
      // with the rest.
      acceptFramePart(value)
      return
    }

    if characteristic.uuid == QuickShareBluetoothIDs.data, !value.isEmpty {
      // Nothing is sent here any more. Bytes are an older sender.
      refuseStaleSender()
    }
  }
}
