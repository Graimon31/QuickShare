import Flutter
import MobileCoreServices
import UIKit
import UniformTypeIdentifiers

/// Picking folders — more than one of them — to send.
///
/// `file_picker`'s `getDirectoryPath()` opens the same system picker but with
/// multiple selection off, and iOS draws that mode without checkboxes: a
/// folder cannot be ticked, only entered and confirmed from the inside. That
/// makes "send these three folders" impossible to express, which is the whole
/// reason this exists. `allowsMultipleSelection = true` is the entire
/// difference in behaviour, and the plugin has no way to ask for it.
///
/// The second half is access. A folder outside the app's container is not
/// readable just because the user pointed at it: the URL arrives
/// security-scoped and stays unreadable until `startAccessingSecurityScopedResource`
/// opens it. Dart's `Directory.list()` would see an empty folder otherwise —
/// which is exactly how "I picked it and nothing was sent" happens. The
/// scopes stay open until the next pick replaces them, because the session
/// that reads those files runs long after this call returns: indexing, then
/// serving every byte over the wire.
public class FolderPickerPlugin: NSObject {
  private var pending: FlutterResult?
  private var scopedURLs: [URL] = []

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "quickshare/folder_picker",
      binaryMessenger: registrar.messenger()
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
      present(result: result)
    case "releaseFolders":
      releaseScopes()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func present(result: @escaping FlutterResult) {
    guard pending == nil else {
      result(FlutterError(code: "BUSY", message: "a folder picker is already open", details: nil))
      return
    }

    guard let root = Self.topViewController() else {
      result(FlutterError(code: "NO_WINDOW", message: "nothing to present from", details: nil))
      return
    }

    pending = result

    let picker: UIDocumentPickerViewController
    if #available(iOS 14.0, *) {
      picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.folder], asCopy: false)
    } else {
      picker = UIDocumentPickerViewController(documentTypes: [kUTTypeFolder as String], in: .open)
    }
    picker.allowsMultipleSelection = true
    picker.delegate = self
    picker.modalPresentationStyle = .formSheet
    root.present(picker, animated: true)
  }

  /// Closes every scope this plugin opened.
  ///
  /// Called before a new pick rather than after a transfer: releasing while
  /// files are still being read would cut a send off mid-flight, and the
  /// next pick is the first moment the previous selection is certainly done
  /// with. The count is bounded by one selection either way.
  private func releaseScopes() {
    for url in scopedURLs {
      url.stopAccessingSecurityScopedResource()
    }
    scopedURLs.removeAll()
  }

  private static func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let window = scenes.flatMap { $0.windows }.first { $0.isKeyWindow }
      ?? scenes.first?.windows.first
    var top = window?.rootViewController
    while let presented = top?.presentedViewController {
      top = presented
    }
    return top
  }
}

extension FolderPickerPlugin: UIDocumentPickerDelegate {
  public func documentPicker(
    _ controller: UIDocumentPickerViewController,
    didPickDocumentsAt urls: [URL]
  ) {
    releaseScopes()

    var paths: [String] = []
    for url in urls {
      // A folder whose scope refuses to open is reported anyway: Dart finds
      // it empty and says so, which is a better failure than silently
      // dropping a folder the user watched themselves select.
      if url.startAccessingSecurityScopedResource() {
        scopedURLs.append(url)
      }
      paths.append(url.path)
    }

    pending?(paths)
    pending = nil
  }

  public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    pending?([String]())
    pending = nil
  }
}
