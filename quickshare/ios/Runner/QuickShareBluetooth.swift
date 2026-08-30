import Foundation
import Flutter
import CoreBluetooth

/// iOS CoreBluetooth bridge for QuickShare's BLE transport.
///
/// The same GATT protocol is used by the macOS and iOS sender implementations:
/// the sender advertises a QR-derived session prefix, the receiver subscribes
/// to metadata/data notifications, and writes the received file into the app's
/// Documents directory supplied by Dart.
/// One file inside a Bluetooth session.
///
/// `relativePath` is the path the file keeps on the far side, root folder
/// included — `Trip/Day 1/IMG_0042.HEIC`. It is what lets a folder cross this
/// channel as a folder: before it, the bridge could advertise exactly one
/// object of a known size, so a folder had to be zipped into one first and
/// arrived as an archive to unpack.
private struct QuickShareSenderItem {
  let path: String
  let name: String
  let relativePath: String
  let size: Int
  let mime: String
}

/// The control-characteristic vocabulary, mirrored from
/// `lib/core/transfer/ble_control_protocol.dart`. See that file for why a
/// receiver announces itself before it starts a transfer.
private enum QuickShareBleControl {
  /// 1 — one file per session. 2 — a list of files carrying relative paths.
  static let generation = 2

  static func capabilities() -> String { "CAPS:\(generation)" }

  /// The generation a command announces, or nil if it is not a CAPS write.
  static func parseCapabilities(_ command: String) -> Int? {
    guard command.hasPrefix("CAPS:") else { return nil }
    return Int(command.dropFirst(5).trimmingCharacters(in: .whitespaces))
  }

  static func isStart(_ command: String?, token: String?) -> Bool {
    guard let command else { return false }
    if command == "START" { return true }
    guard let token else { return false }
    return command == "START:\(token)"
  }
}

private enum QuickShareBluetoothIDs {
  static let service = CBUUID(string: "E9C1F384-1D30-4B77-8B8B-9E1A7D5F6B10")
  static let control = CBUUID(string: "E9C1F384-1D30-4B77-8B8B-9E1A7D5F6B11")
  static let metadata = CBUUID(string: "E9C1F384-1D30-4B77-8B8B-9E1A7D5F6B12")
  static let data = CBUUID(string: "E9C1F384-1D30-4B77-8B8B-9E1A7D5F6B13")
}

public final class QuickShareBluetoothPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private var eventSink: FlutterEventSink?
  private var centralManager: CBCentralManager?
  private var discovered: [String: CBPeripheral] = [:]
  private var expectedSessionToken: String?
  private var pendingStartScan = false
  private var targetPeripheral: CBPeripheral?
  private var remoteControl: CBCharacteristic?
  private var metadataSubscribed = false
  private var dataSubscribed = false

  // Peripheral (sender) state. iOS supports both central and peripheral
  // roles, so the phone can send directly to the existing macOS/iOS receiver.
  private var peripheralManager: CBPeripheralManager?
  private var pendingServiceToAdd: CBMutableService?
  private var pendingDeviceName: String?
  private var senderControl: CBMutableCharacteristic?
  private var senderMetadata: CBMutableCharacteristic?
  private var senderData: CBMutableCharacteristic?
  private var senderFileHandle: FileHandle?

  /// The session, in send order, and where the pump has got to inside it.
  private var senderItems: [QuickShareSenderItem] = []
  private var senderItemIndex = 0
  private var senderItemBytesSent = 0

  /// Counted across the whole session, so a folder of forty photos fills one
  /// progress ring rather than forty.
  private var senderTotalBytes = 0
  private var senderBytesSent = 0

  /// The metadata frame for the file about to be sent, still waiting for room
  /// in the notification queue. Its bytes must not start before it lands, or
  /// the receiver files them under the previous file.
  private var senderPendingMetadata: Data?
  private var senderSessionToken: String?

  /// What the receiver said it can take, from its `CAPS:` write. Nil means it
  /// never sent one — a build that stops at the first file of a session.
  private var senderPeerGeneration: Int?
  private var senderSubscribedCentral: CBCentral?
  private var senderTransferStarted = false

  private var receiveTargetDirectory: String?
  private var receiveFilePath: String?
  private var receiveFileHandle: FileHandle?
  private var receiveFileName = "received_file"

  /// Session totals — every file the sender announced, and every byte of them
  /// that has landed. What the progress ring and the disconnect check use.
  private var receiveTotalBytes = 0
  private var receiveBytes = 0

  /// The file currently open, and where the session is in its list.
  private var receiveFileTotalBytes = 0
  private var receiveFileBytes = 0
  private var receiveItemIndex = 0
  private var receiveItemCount = 1
  private var receivedPaths: [String] = []

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
      startScanning(sessionToken: args?["sessionToken"] as? String)
      result(nil)

    case "stopScanning":
      stopScanning()
      result(nil)

    case "connect":
      guard let args = call.arguments as? [String: Any],
            let deviceId = args["deviceId"] as? String,
            let targetDir = args["targetDir"] as? String else {
        result(FlutterError(code: "BAD_ARGS", message: "deviceId/targetDir required", details: nil))
        return
      }
      connect(deviceId: deviceId, targetDir: targetDir)
      result(nil)

    case "cancelTransfer":
      cancelTransfer()
      result(nil)

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

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func startScanning(sessionToken: String?) {
    discovered.removeAll()
    expectedSessionToken = sessionToken
    let manager = centralManager ?? CBCentralManager(delegate: self, queue: nil)
    centralManager = manager
    if manager.state == .poweredOn {
      manager.scanForPeripherals(withServices: [QuickShareBluetoothIDs.service], options: nil)
    } else {
      pendingStartScan = true
    }
  }

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
    receiveTargetDirectory = targetDir
    receiveFilePath = nil
    receiveFileHandle?.closeFile()
    receiveFileHandle = nil
    receiveTotalBytes = 0
    receiveBytes = 0
    receiveFileTotalBytes = 0
    receiveFileBytes = 0
    receiveItemIndex = 0
    receiveItemCount = 1
    receivedPaths = []
    metadataSubscribed = false
    dataSubscribed = false
    remoteControl = nil
    peripheral.delegate = self
    emit(["type": "connecting"])
    centralManager?.connect(peripheral, options: nil)
  }

  private func cancelTransfer() {
    stopScanning()
    stopAdvertising()
    if let peripheral = targetPeripheral {
      centralManager?.cancelPeripheralConnection(peripheral)
    }
    receiveFileHandle?.closeFile()
    receiveFileHandle = nil
    targetPeripheral = nil
  }

  // MARK: Peripheral sender

  /// Reads the session out of the method-channel arguments.
  ///
  /// `files` is what Dart sends now. The single-file keys beside it are what
  /// every earlier build sent, and they are still read so a mismatched pair of
  /// binaries degrades to the one-file session it used to be rather than
  /// failing outright.
  private static func senderItems(from args: [String: Any]) -> [QuickShareSenderItem] {
    if let raw = args["files"] as? [[String: Any]], !raw.isEmpty {
      return raw.compactMap { entry in
        guard let path = entry["filePath"] as? String,
              let name = entry["fileName"] as? String,
              let size = entry["fileSize"] as? Int else { return nil }
        return QuickShareSenderItem(
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
    return [QuickShareSenderItem(
      path: path,
      name: name,
      relativePath: name,
      size: max(size, 0),
      mime: args["mimeType"] as? String ?? "application/octet-stream"
    )]
  }

  private func startAdvertising(items: [QuickShareSenderItem], sessionToken: String?) {
    stopAdvertising()
    senderItems = items
    senderItemIndex = 0
    senderItemBytesSent = 0
    senderTotalBytes = items.reduce(0) { $0 + $1.size }
    senderBytesSent = 0
    senderSessionToken = sessionToken
    senderTransferStarted = false
    senderSubscribedCentral = nil
    senderPendingMetadata = nil
    senderPeerGeneration = nil
    senderFileHandle = nil

    // Opened here rather than at START so an unreadable file is reported while
    // the sender is still looking at their own screen.
    guard openCurrentSenderItem() else { return }

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
    pendingDeviceName = sessionToken.map { "QuickShare-\(String($0.prefix(8)))" } ?? "QuickShare"
    peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
  }

  private func stopAdvertising() {
    peripheralManager?.stopAdvertising()
    peripheralManager?.removeAllServices()
    peripheralManager = nil
    pendingServiceToAdd = nil
    pendingDeviceName = nil
    senderFileHandle?.closeFile()
    senderFileHandle = nil
    senderControl = nil
    senderMetadata = nil
    senderData = nil
    senderPendingMetadata = nil
    senderItems = []
    senderItemIndex = 0
    senderItemBytesSent = 0
    senderSubscribedCentral = nil
    senderTransferStarted = false
    senderSessionToken = nil
    senderPeerGeneration = nil
  }

  /// Opens the file at [senderItemIndex] and queues its metadata frame.
  ///
  /// Returns false, having reported the failure, when the file cannot be read.
  @discardableResult
  private func openCurrentSenderItem() -> Bool {
    guard senderItemIndex < senderItems.count else { return false }
    let item = senderItems[senderItemIndex]
    guard let handle = FileHandle(forReadingAtPath: item.path) else {
      emit(["type": "senderFailed", "error": "Could not open file for reading: \(item.path)"])
      return false
    }
    senderFileHandle = handle
    senderItemBytesSent = 0
    let metadata: [String: Any] = [
      "name": item.name,
      // The relative path the receiver rebuilds the folder from.
      "path": item.relativePath,
      "size": item.size,
      "mime": item.mime,
      "index": senderItemIndex,
      "count": senderItems.count,
      "sessionBytes": senderTotalBytes,
    ]
    senderPendingMetadata = try? JSONSerialization.data(withJSONObject: metadata)
    return true
  }

  private func beginSenderTransferIfReady() {
    guard !senderTransferStarted,
          senderSubscribedCentral != nil,
          senderMetadata != nil,
          senderPendingMetadata != nil else { return }

    // A receiver older than this protocol treats the first file's last byte
    // as the end of the transfer and disconnects. It then shows a completed
    // transfer holding one file, with nothing to say a folder was sent —
    // which is worse than any error, because nobody goes looking for what is
    // missing. One file is still sent to anyone.
    if senderItems.count > 1,
       (senderPeerGeneration ?? 1) < QuickShareBleControl.generation {
      senderTransferStarted = true
      emit([
        "type": "senderFailed",
        "error": "The receiving device is on an older version that can only accept one file over Bluetooth. Update it, or send over Wi-Fi.",
      ])
      return
    }

    senderTransferStarted = true
    pumpSenderQueue()
  }

  /// Sends as much of the session as the notification queue will take.
  ///
  /// One loop for the whole list rather than one per file: each item's
  /// metadata goes out, then its bytes, then the next item's metadata. Any
  /// `updateValue` can refuse for want of room, at which point this returns
  /// and `peripheralManagerIsReady(toUpdateSubscribers:)` calls it again —
  /// which is why the pending metadata and the file offset are both state and
  /// not locals.
  private func pumpSenderQueue() {
    guard let manager = peripheralManager,
          let dataCharacteristic = senderData,
          let metadataCharacteristic = senderMetadata else { return }

    let mtu = senderSubscribedCentral?.maximumUpdateValueLength ?? 182
    let chunkSize = max(mtu - 3, 20)

    while senderItemIndex < senderItems.count {
      if let pending = senderPendingMetadata {
        if !manager.updateValue(pending, for: metadataCharacteristic, onSubscribedCentrals: nil) {
          return
        }
        senderPendingMetadata = nil
      }

      let item = senderItems[senderItemIndex]
      guard let handle = senderFileHandle else { return }

      while senderItemBytesSent < item.size {
        let chunk = handle.readData(ofLength: chunkSize)
        if chunk.isEmpty { break }
        if !manager.updateValue(chunk, for: dataCharacteristic, onSubscribedCentrals: nil) {
          handle.seek(toFileOffset: UInt64(senderItemBytesSent))
          return
        }
        senderItemBytesSent += chunk.count
        senderBytesSent += chunk.count
        emit(["type": "senderProgress", "sent": senderBytesSent, "total": senderTotalBytes])
      }

      guard senderItemBytesSent >= item.size else {
        handle.closeFile()
        senderFileHandle = nil
        emit(["type": "senderFailed", "error": "\(item.name) ended after \(senderItemBytesSent) of \(item.size) bytes"])
        return
      }

      handle.closeFile()
      senderFileHandle = nil
      senderItemIndex += 1
      if senderItemIndex < senderItems.count {
        guard openCurrentSenderItem() else { return }
      }
    }

    emit(["type": "senderCompleted"])
  }

  private func uniquePath(_ path: String) -> String {
    let fileManager = FileManager.default
    if !fileManager.fileExists(atPath: path) { return path }
    let url = URL(fileURLWithPath: path)
    let ext = url.pathExtension
    let stem = url.deletingPathExtension().lastPathComponent
    let directory = url.deletingLastPathComponent()
    var index = 1
    var candidate = path
    while fileManager.fileExists(atPath: candidate) {
      let suffix = ext.isEmpty ? "\(stem) (\(index))" : "\(stem) (\(index)).\(ext)"
      candidate = directory.appendingPathComponent(suffix).path
      index += 1
    }
    return candidate
  }

  /// Where a file announced as [relative] is written, under [directory].
  ///
  /// Every segment came off the wire, so every segment is put through the same
  /// filename cleaner as a flat name, and `.`/`..` are dropped rather than
  /// resolved — a sender cannot name its way out of the destination. The
  /// containment check afterwards is deliberate belt and braces.
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
    if let path = receiveFilePath, !receivedPaths.contains(path) {
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

extension QuickShareBluetoothPlugin: CBCentralManagerDelegate {
  public func centralManagerDidUpdateState(_ central: CBCentralManager) {
    if central.state == .poweredOn, pendingStartScan {
      pendingStartScan = false
      central.scanForPeripherals(withServices: [QuickShareBluetoothIDs.service], options: nil)
    } else if central.state == .unauthorized || central.state == .unsupported {
      emit(["type": "receiverFailed", "error": "Bluetooth is not available or not authorized"])
    }
  }

  public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
    let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "Unknown device"
    if let expectedSessionToken,
       !name.contains(String(expectedSessionToken.prefix(8))) &&
       name.hasPrefix("QuickShare-") {
      return
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
    emit(["type": "receiverFailed", "error": "Failed to connect: \(error?.localizedDescription ?? "unknown error")"])
  }

  public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
    // Session totals, not the current file's: a folder is finished when the
    // whole list has landed, not when its last photo has.
    if receiveTotalBytes == 0 || receiveBytes < receiveTotalBytes {
      emit(["type": "receiverFailed", "error": "Sender disconnected before the transfer finished"])
    }
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
    senderSubscribedCentral = central
    emit(["type": "centralConnected"])
  }

  public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
    for request in requests {
      let command = request.value.flatMap { String(data: $0, encoding: .utf8) }

      guard request.characteristic.uuid == QuickShareBluetoothIDs.control else {
        peripheral.respond(to: request, withResult: .requestNotSupported)
        continue
      }

      // Always ahead of START, so it is on record before the decision about
      // what this session may send is taken.
      if let command, let generation = QuickShareBleControl.parseCapabilities(command) {
        senderPeerGeneration = generation
        peripheral.respond(to: request, withResult: .success)
        continue
      }

      if QuickShareBleControl.isStart(command, token: senderSessionToken) {
        peripheral.respond(to: request, withResult: .success)
        beginSenderTransferIfReady()
      } else {
        peripheral.respond(to: request, withResult: .requestNotSupported)
      }
    }
  }

  public func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
    pumpSenderQueue()
  }
}

extension QuickShareBluetoothPlugin: CBPeripheralDelegate {
  public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    guard let service = peripheral.services?.first(where: { $0.uuid == QuickShareBluetoothIDs.service }) else {
      emit(["type": "receiverFailed", "error": "QuickShare service not found on device"])
      return
    }
    peripheral.discoverCharacteristics(
      [QuickShareBluetoothIDs.control, QuickShareBluetoothIDs.metadata, QuickShareBluetoothIDs.data],
      for: service
    )
  }

  public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    guard let characteristics = service.characteristics else { return }
    for characteristic in characteristics {
      switch characteristic.uuid {
      case QuickShareBluetoothIDs.control:
        remoteControl = characteristic
      case QuickShareBluetoothIDs.metadata, QuickShareBluetoothIDs.data:
        peripheral.setNotifyValue(true, for: characteristic)
      default:
        break
      }
    }
  }

  public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
    if characteristic.uuid == QuickShareBluetoothIDs.metadata { metadataSubscribed = true }
    if characteristic.uuid == QuickShareBluetoothIDs.data { dataSubscribed = true }
    guard metadataSubscribed, dataSubscribed, let control = remoteControl else { return }
    let writeType: CBCharacteristicWriteType = control.properties.contains(.write) ? .withResponse : .withoutResponse

    // Say what this build can take, before START rather than after. A sender
    // that reaches START without having seen this knows the far side is old
    // and refuses to half-deliver a folder to it.
    //
    // Senders up to v1.0.10 answer this with an ATT error, which is not a
    // failed connection: it is an older sender behaving exactly as it always
    // did, and the one-file transfer that follows is a good one. The error
    // lands in didWriteValueFor, which this class deliberately does not
    // implement.
    peripheral.writeValue(Data(QuickShareBleControl.capabilities().utf8), for: control, type: writeType)

    let command = expectedSessionToken.map { "START:\($0)" } ?? "START"
    peripheral.writeValue(Data(command.utf8), for: control, type: writeType)
  }

  public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
    if let error {
      emit(["type": "receiverFailed", "error": error.localizedDescription])
      return
    }
    guard let value = characteristic.value else { return }

    if characteristic.uuid == QuickShareBluetoothIDs.metadata {
      guard let json = try? JSONSerialization.jsonObject(with: value) as? [String: Any],
            let name = json["name"] as? String,
            let size = json["size"] as? Int else {
        emit(["type": "receiverFailed", "error": "Malformed metadata from sender"])
        return
      }

      // A metadata frame is this channel's only end-of-file marker: whatever
      // is open belongs to the item before this one.
      sealCurrentReceiveFile()

      receiveFileName = sanitizeFileName(name)
      receiveFileTotalBytes = size
      receiveFileBytes = 0
      receiveItemIndex = json["index"] as? Int ?? 0
      // A sender that says nothing is a sender with one file, which is what
      // every build before folders could carry.
      receiveItemCount = json["count"] as? Int ?? 1
      if receiveItemIndex <= 0 {
        receiveBytes = 0
        receivedPaths = []
        receiveTotalBytes = json["sessionBytes"] as? Int ?? size
      }

      let directory = receiveTargetDirectory ?? NSTemporaryDirectory()
      let relative = json["path"] as? String ?? name
      guard let target = resolveReceivePath(relative, in: directory) else {
        emit(["type": "receiverFailed", "error": "Path traversal detected in \"\(relative)\""])
        return
      }
      do {
        // The folder the sender kept has to exist before its first file can go
        // into it, and directories are created as their contents arrive.
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
      guard let handle = FileHandle(forWritingAtPath: path) else {
        emit(["type": "receiverFailed", "error": "Cannot open destination file"])
        return
      }
      receiveFilePath = path
      receiveFileHandle = handle
      emit(["type": "metadataReceived", "name": receiveFileName, "size": receiveTotalBytes])
      return
    }

    guard characteristic.uuid == QuickShareBluetoothIDs.data else { return }
    receiveFileHandle?.write(value)
    receiveFileBytes += value.count
    receiveBytes += value.count
    emit(["type": "receiverProgress", "received": receiveBytes, "total": receiveTotalBytes])
    if receiveFileTotalBytes > 0, receiveFileBytes >= receiveFileTotalBytes {
      sealCurrentReceiveFile()
      // The last item the sender announced, with all of its bytes in: that is
      // the session, and nothing further is coming.
      if receiveItemIndex >= receiveItemCount - 1 {
        emit(["type": "receiverCompleted", "path": receivedPaths.first ?? receiveFilePath ?? ""])
        centralManager?.cancelPeripheralConnection(peripheral)
      }
    }
  }
}
