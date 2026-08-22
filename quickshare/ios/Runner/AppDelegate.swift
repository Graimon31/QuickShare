import UIKit
import Flutter

@main
@objc class AppDelegate: FlutterAppDelegate {
  // Held for the lifetime of the app: it tracks which networks we joined so
  // they can be removed again, and a local would be deallocated immediately.
  private let hotspotBridge = HotspotBridge()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    let result = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    if let registrar = self.registrar(forPlugin: "QuickShareBluetoothPlugin") {
      QuickShareBluetoothPlugin.register(with: registrar)
    }
    if let controller = window?.rootViewController as? FlutterViewController {
      hotspotBridge.register(with: controller.binaryMessenger)
    }
    return result
  }
}
