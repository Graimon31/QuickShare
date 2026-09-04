import Cocoa
import FlutterMacOS

/// Picking folders — more than one of them — to send.
///
/// `file_picker`'s `getDirectoryPath()` opens an `NSOpenPanel` with
/// `allowsMultipleSelection` off and hands back a single path, so "send these
/// three folders" cannot be expressed at all. The panel itself has no trouble
/// with it; the plugin's API is what has no room for the answer.
///
/// Nothing is held open afterwards, unlike the iOS side: the sandbox grants
/// this process access to whatever the user picked in an open panel for as
/// long as it runs, under `com.apple.security.files.user-selected.read-write`.
/// A folder that has to survive a restart is a different problem, and
/// [SaveLocationPlugin] already solves that one with a bookmark.
public class FolderPickerPlugin: NSObject {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "quickshare/folder_picker",
      binaryMessenger: registrar.messenger
    )
    let instance = FolderPickerPlugin()
    channel.setMethodCallHandler { call, result in
      instance.handle(call, result: result)
    }
    objc_setAssociatedObject(channel, "folder_picker.instance", instance, .OBJC_ASSOCIATION_RETAIN)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "pickFolders":
      let title = (call.arguments as? [String: Any])?["title"] as? String
      openPanel(title: title, files: false, result: result)
    case "pickItems":
      let title = (call.arguments as? [String: Any])?["title"] as? String
      openPanel(title: title, files: true, result: result)
    case "exportItems":
      // macOS can write wherever the user pointed, under the
      // user-selected-read-write entitlement, so "save these" is the same
      // open panel plus a copy Dart performs itself. Only iOS needs the
      // system to do the copying.
      let title = (call.arguments as? [String: Any])?["title"] as? String
      openPanel(title: title, files: false, result: result)
    case "releaseFolders":
      // Nothing to release: see the note on the class.
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// One panel for both buttons that used to exist.
  ///
  /// `canChooseFiles` and `canChooseDirectories` are not exclusive — an
  /// `NSOpenPanel` has always been able to return a mixed selection of files
  /// and folders in one trip. `file_picker` exposes them as two separate
  /// calls, which is the only reason this app asked the user to decide up
  /// front whether they were sending files or a folder.
  private func openPanel(title: String?, files: Bool, result: @escaping FlutterResult) {
    DispatchQueue.main.async {
      let panel = NSOpenPanel()
      panel.canChooseFiles = files
      panel.canChooseDirectories = true
      panel.allowsMultipleSelection = true
      // Saving into a folder that does not exist yet is an ordinary
      // thing to want, and the panel is the only place to make one.
      panel.canCreateDirectories = true
      panel.resolvesAliases = true
      if let title = title {
        panel.message = title
      }

      let finish: (NSApplication.ModalResponse) -> Void = { response in
        guard response == .OK else {
          result([String]())
          return
        }
        result(panel.urls.map { $0.path })
      }

      if let window = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first {
        panel.beginSheetModal(for: window, completionHandler: finish)
      } else {
        finish(panel.runModal())
      }
    }
  }
}
