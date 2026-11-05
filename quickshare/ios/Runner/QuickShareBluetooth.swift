import Foundation
import Flutter
import CoreBluetooth
import UIKit

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

public final class QuickShareBluetoothPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private var eventSink: FlutterEventSink?

  // Central (receiver) state.
  private var centralManager: CBCentralManager?
  private var discovered: [String: CBPeripheral] = [:]
  private var expectedSessionToken: String?
  private var expectedLocator: String?
  private var pendingStartScan = false
  private var targetPeripheral: CBPeripheral?
  private var remoteControl: CBCharacteristic?
  private var metadataSubscribed = false
  private var dataSubscribed = false
  private var centralConnectTimeoutTimer: Timer?

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
  private var senderTransferStarted = false

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
                    locator: args?["locator"] as? String)
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
      guard let metadata = senderMetadata, let manager = peripheralManager else {
        result(FlutterError(code: "UNAVAILABLE", message: "no link channel is up", details: nil))
        return
      }
      if manager.updateValue(data, for: metadata, onSubscribedCentrals: nil) {
        result(nil)
      } else {
        result(FlutterError(code: "BUSY", message: "the notification queue is full", details: nil))
      }

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

  private func startScanning(sessionToken: String?, locator: String? = nil) {
    discovered.removeAll()
    expectedSessionToken = sessionToken
    expectedLocator = locator
    let manager = centralManager ?? CBCentralManager(delegate: self, queue: nil)
    centralManager = manager
    let options: [String: Any] = [CBCentralManagerScanOptionAllowDuplicatesKey: true]
    if manager.state == .poweredOn {
      manager.scanForPeripherals(withServices: [QuickShareBluetoothIDs.service], options: options)
    } else {
      pendingStartScan = true
    }
  }

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
    metadataSubscribed = false
    dataSubscribed = false
    remoteControl = nil
    reportedStaleSender = false
    pendingControlWrites.removeAll()
    peripheral.delegate = self

    centralConnectTimeoutTimer?.invalidate()
    centralConnectTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
      guard let self = self, self.targetPeripheral != nil, self.remoteControl == nil else { return }
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

  private func cancelTransfer() {
    centralConnectTimeoutTimer?.invalidate()
    centralConnectTimeoutTimer = nil
    stopScanning()
    stopAdvertising()
    if let peripheral = targetPeripheral {
      centralManager?.cancelPeripheralConnection(peripheral)
    }
    targetPeripheral = nil
    remoteControl = nil
    metadataSubscribed = false
    dataSubscribed = false
    pendingControlWrites.removeAll()
    discovered.removeAll()
  }

  // MARK: Peripheral sender

  private func startAdvertising(sessionToken: String?, locator: String? = nil) {
    stopAdvertising()
    senderSessionToken = sessionToken
    senderTransferStarted = false
    senderSubscribedToData = false
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
    peripheralManager?.stopAdvertising()
    peripheralManager?.removeAllServices()
    peripheralManager = nil
    pendingServiceToAdd = nil
    pendingDeviceName = nil
    senderControl = nil
    senderMetadata = nil
    senderData = nil
    senderSubscribedToData = false
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
    if central.state == .poweredOn, pendingStartScan {
      pendingStartScan = false
      central.scanForPeripherals(withServices: [QuickShareBluetoothIDs.service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    } else if central.state == .unauthorized || central.state == .unsupported {
      emit(["type": "receiverFailed", "error": "Bluetooth is not available or not authorized"])
    }
  }

  public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
    let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "Unknown device"
    // What a sender advertises is the session's locator: random, the one the
    // QR carries, and related to no code. A device with no
    // `QuickShare-` name at all — a Windows PC or an Android phone, which
    // cannot carry one beside the service UUID — is accepted: the scan is
    // already filtered to our service, and the START token is what
    // authenticates. Earlier builds advertised the first eight characters of
    // the token instead, so that match stays as the fallback — dropping it
    // would make this build unable to see them.
    if name.hasPrefix("QuickShare-") {
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
    peripheral.discoverServices([QuickShareBluetoothIDs.service])
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
    remoteControl = nil
    metadataSubscribed = false
    dataSubscribed = false
    pendingControlWrites.removeAll()
    discovered.removeAll()

    // Whether this matters is Dart's call: before the serve frame it ends the
    // session, after it nothing is waiting on the radio.
    emit(["type": "receiverDisconnected"])
  }
}

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
    if let error {
      emit(["type": "senderFailed", "error": "Failed to publish BLE service: \(error.localizedDescription)"])
      return
    }

    peripheral.startAdvertising([
      CBAdvertisementDataServiceUUIDsKey: [QuickShareBluetoothIDs.service],
      CBAdvertisementDataLocalNameKey: pendingDeviceName ?? "QuickShare",
    ])
    emit(["type": "advertisingStarted"])
  }

  public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
    guard characteristic.uuid == QuickShareBluetoothIDs.data else { return }
    senderSubscribedToData = true
    emit(["type": "centralConnected"])
  }

  public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
    if characteristic.uuid == QuickShareBluetoothIDs.data {
      senderSubscribedToData = false
    }
  }

  public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
    for request in requests {
      let command = request.value.flatMap { String(data: $0, encoding: .utf8) }

      guard request.characteristic.uuid == QuickShareBluetoothIDs.control else {
        peripheral.respond(to: request, withResult: .requestNotSupported)
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
    if let error = error {
      centralConnectTimeoutTimer?.invalidate()
      centralConnectTimeoutTimer = nil
      emit(["type": "receiverFailed", "error": "Service discovery failed: \(error.localizedDescription)"])
      return
    }
    guard let service = peripheral.services?.first(where: { $0.uuid == QuickShareBluetoothIDs.service }) else {
      centralConnectTimeoutTimer?.invalidate()
      centralConnectTimeoutTimer = nil
      emit(["type": "receiverFailed", "error": "QuickShare service not found on device"])
      return
    }
    peripheral.discoverCharacteristics(
      [QuickShareBluetoothIDs.control, QuickShareBluetoothIDs.metadata, QuickShareBluetoothIDs.data],
      for: service
    )
  }

  public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    if let error = error {
      centralConnectTimeoutTimer?.invalidate()
      centralConnectTimeoutTimer = nil
      emit(["type": "receiverFailed", "error": "Characteristic discovery failed: \(error.localizedDescription)"])
      return
    }
    guard let characteristics = service.characteristics else {
      centralConnectTimeoutTimer?.invalidate()
      centralConnectTimeoutTimer = nil
      emit(["type": "receiverFailed", "error": "No characteristics found on device"])
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
    if let error = error {
      centralConnectTimeoutTimer?.invalidate()
      centralConnectTimeoutTimer = nil
      emit(["type": "receiverFailed", "error": "Failed to subscribe to notifications: \(error.localizedDescription)"])
      return
    }
    if characteristic.uuid == QuickShareBluetoothIDs.metadata { metadataSubscribed = true }
    if characteristic.uuid == QuickShareBluetoothIDs.data { dataSubscribed = true }
    guard metadataSubscribed, dataSubscribed, let control = remoteControl else { return }
    centralConnectTimeoutTimer?.invalidate()
    centralConnectTimeoutTimer = nil
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
  }

  public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
    if let error {
      emit(["type": "receiverFailed", "error": error.localizedDescription])
      return
    }
    guard let value = characteristic.value else { return }

    if characteristic.uuid == QuickShareBluetoothIDs.metadata {
      if let text = String(data: value, encoding: .utf8) {
        if let sealed = QuickShareBleControl.parseApOffer(text) {
          emit(["type": "apOffer", "sealed": sealed])
          return
        }
        if let key = QuickShareBleControl.parseKeyExchange(text) {
          emit(["type": "peerKey", "key": key])
          return
        }
      }
      // A link frame is not a file: the sender is negotiating the Wi-Fi
      // network the transfer will actually cross (generation 4), and a serve
      // frame says where on it the file then is.
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
      // Anything else on this characteristic is the first frame of a file from
      // a sender that predates the direct link — or half a frame, cut by a
      // connection that carries too little.
      refuseStaleSender()
      return
    }

    if characteristic.uuid == QuickShareBluetoothIDs.data, !value.isEmpty {
      // Nothing is sent here any more. Bytes are an older sender.
      refuseStaleSender()
    }
  }
}
