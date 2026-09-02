import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    // Fixed window dimensions sized to show both home actions without scrolling.
    let windowSize = NSSize(width: 680, height: 720)
    self.setContentSize(windowSize)
    self.minSize = windowSize
    self.maxSize = windowSize

    // Disable window resizing and disable macOS fullscreen mode (zoom button)
    self.styleMask.remove(.resizable)
    self.collectionBehavior.remove(.fullScreenPrimary)
    self.collectionBehavior.insert(.fullScreenNone)
    self.standardWindowButton(.zoomButton)?.isEnabled = false

    RegisterGeneratedPlugins(registry: flutterViewController)
    QuickShareBluetoothPlugin.register(with: flutterViewController.registrar(forPlugin: "QuickShareBluetoothPlugin"))
    PeerLinkPlugin.register(with: flutterViewController.registrar(forPlugin: "PeerLinkPlugin"))
    SaveLocationPlugin.register(with: flutterViewController.registrar(forPlugin: "SaveLocationPlugin"))
    FolderPickerPlugin.register(with: flutterViewController.registrar(forPlugin: "FolderPickerPlugin"))

    super.awakeFromNib()
  }
}
