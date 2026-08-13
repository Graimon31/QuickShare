import Foundation
import Flutter
import CoreBluetooth

/// iOS CoreBluetooth bridge for QuickShare's BLE transport.
///
/// The same GATT protocol is used by the macOS and iOS sender implementations:
/// the sender advertises a QR-derived session prefix, the receiver subscribes
/// to metadata/data notifications, and writes the received file into the app's
/// Documents directory supplied by Dart.
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
  private var senderTotalBytes = 0
  private var senderBytesSent = 0
  private var senderMetadataJSON: Data?
  private var senderSessionToken: String?
  private var senderSubscribedCentral: CBCentral?
  private var senderTransferStarted = false

  private var receiveTargetDirectory: String?
  private var receiveFilePath: String?
  private var receiveFileHandle: FileHandle?
  private var receiveFileName = "received_file"
  private var receiveTotalBytes = 0
  private var receiveBytes = 0

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
      guard let args = call.arguments as? [String: Any],
            let filePath = args["filePath"] as? String,
            let fileName = args["fileName"] as? String,
            let fileSize = args["fileSize"] as? Int else {
        result(FlutterError(code: "BAD_ARGS", message: "filePath/fileName/fileSize required", details: nil))
        return
      }
      startAdvertising(
        filePath: filePath,
        fileName: fileName,
        fileSize: fileSize,
        mime: args["mimeType"] as? String ?? "application/octet-stream",
        sessionToken: args["sessionToken"] as? String
      )
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

  private func startAdvertising(filePath: String, fileName: String, fileSize: Int, mime: String, sessionToken: String?) {
    stopAdvertising()
    senderTotalBytes = max(fileSize, 0)
    senderBytesSent = 0
    senderSessionToken = sessionToken
    senderTransferStarted = false
    senderSubscribedCentral = nil
    senderFileHandle = FileHandle(forReadingAtPath: filePath)

    guard senderFileHandle != nil else {
      emit(["type": "senderFailed", "error": "Could not open file for reading: \(filePath)"])
      return
    }

    let metadata: [String: Any] = ["name": fileName, "size": senderTotalBytes, "mime": mime]
    senderMetadataJSON = try? JSONSerialization.data(withJSONObject: metadata)

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
    senderMetadataJSON = nil
    senderSubscribedCentral = nil
    senderTransferStarted = false
    senderSessionToken = nil
  }

  private func beginSenderTransferIfReady() {
    guard !senderTransferStarted,
          senderSubscribedCentral != nil,
          let metadataCharacteristic = senderMetadata,
          let metadata = senderMetadataJSON else { return }

    senderTransferStarted = true
    _ = peripheralManager?.updateValue(metadata, for: metadataCharacteristic, onSubscribedCentrals: nil)
    pumpSenderQueue()
  }

  private func pumpSenderQueue() {
    guard let manager = peripheralManager,
          let dataCharacteristic = senderData,
          let handle = senderFileHandle else { return }

    let mtu = senderSubscribedCentral?.maximumUpdateValueLength ?? 182
    let chunkSize = max(mtu - 3, 20)

    while senderBytesSent < senderTotalBytes {
      let chunk = handle.readData(ofLength: chunkSize)
      if chunk.isEmpty { break }
      if !manager.updateValue(chunk, for: dataCharacteristic, onSubscribedCentrals: nil) {
        handle.seek(toFileOffset: UInt64(senderBytesSent))
        return
      }
      senderBytesSent += chunk.count
      emit(["type": "senderProgress", "sent": senderBytesSent, "total": senderTotalBytes])
    }

    if senderBytesSent >= senderTotalBytes {
      emit(["type": "senderCompleted"])
      senderFileHandle?.closeFile()
      senderFileHandle = nil
    }
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
      let tokenCommand = senderSessionToken.map { "START:\($0)" }
      let isValidStart = command == "START" || command == tokenCommand

      if request.characteristic.uuid == QuickShareBluetoothIDs.control, isValidStart {
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
    let command = expectedSessionToken.map { "START:\($0)" } ?? "START"
    let writeType: CBCharacteristicWriteType = control.properties.contains(.write) ? .withResponse : .withoutResponse
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
      receiveFileName = sanitizeFileName(name)
      receiveTotalBytes = size
      receiveBytes = 0
      let directory = receiveTargetDirectory ?? NSTemporaryDirectory()
      do {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
      } catch {
        emit(["type": "receiverFailed", "error": "Cannot create destination directory: \(error.localizedDescription)"])
        return
      }
      let path = uniquePath(URL(fileURLWithPath: directory).appendingPathComponent(receiveFileName).path)
      FileManager.default.createFile(atPath: path, contents: nil)
      guard let handle = FileHandle(forWritingAtPath: path) else {
        emit(["type": "receiverFailed", "error": "Cannot open destination file"])
        return
      }
      receiveFilePath = path
      receiveFileHandle = handle
      emit(["type": "metadataReceived", "name": receiveFileName, "size": size])
      return
    }

    guard characteristic.uuid == QuickShareBluetoothIDs.data else { return }
    receiveFileHandle?.write(value)
    receiveBytes += value.count
    emit(["type": "receiverProgress", "received": receiveBytes, "total": receiveTotalBytes])
    if receiveTotalBytes > 0, receiveBytes >= receiveTotalBytes {
      receiveFileHandle?.closeFile()
      receiveFileHandle = nil
      emit(["type": "receiverCompleted", "path": receiveFilePath ?? ""])
      centralManager?.cancelPeripheralConnection(peripheral)
    }
  }
}
