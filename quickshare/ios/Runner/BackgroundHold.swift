import Flutter
import UIKit

/// Extra seconds after the user leaves the app, so a glance at Settings
/// does not kill an in-flight transfer.
///
/// This is not background receiving. iOS still suspends the process when
/// the task expires (~30s). WebRTC will not survive that; QHTP can resume
/// from the byte it stopped at. The hold exists so "I opened Settings to
/// turn Wi-Fi on" is not the same as "I killed the transfer".
///
/// Do not add `voip` to UIBackgroundModes — that got the app terminated on
/// launch.
class BackgroundHoldPlugin: NSObject, FlutterPlugin {
  static let channelName = "directdrop/background_hold"

  private var task = UIBackgroundTaskIdentifier.invalid

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName, binaryMessenger: registrar.messenger())
    let instance = BackgroundHoldPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "begin":
      begin()
      result(nil)
    case "end":
      end()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func begin() {
    if task != .invalid { return }
    task = UIApplication.shared.beginBackgroundTask(withName: "DirectDrop transfer") { [weak self] in
      self?.end()
    }
  }

  private func end() {
    guard task != .invalid else { return }
    UIApplication.shared.endBackgroundTask(task)
    task = .invalid
  }
}
