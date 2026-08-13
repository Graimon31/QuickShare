import UIKit
import Flutter

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    let result = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    if let registrar = self.registrar(forPlugin: "QuickShareBluetoothPlugin") {
      QuickShareBluetoothPlugin.register(with: registrar)
    }
    return result
  }
}
