import Flutter
import MobileCoreServices
import UIKit
import UniformTypeIdentifiers

/// The system file browser, in the three shapes this app needs it.
///
/// `file_picker` opens the same `UIDocumentPickerViewController` for all of
/// them but exposes none of the switches that matter here, and each missing
/// switch was a bug somebody could see:
///
///  * `pickItems` browses for **files and folders together**, several at a
///    time. The plugin has one call for files and another for a single
///    folder, which is why this app had two buttons for what iOS treats as
///    one act of browsing.
///  * `exportItems` saves finished downloads somewhere the user chooses.
///    `getDirectoryPath()` opens the picker in *open* mode, so the button
///    read "Открыть" when the user was plainly saving — and, worse, the
///    folder it returned was outside the sandbox: the app could name the
///    path but not write to it, so every save ended in "не удалось
///    сохранить". In export mode iOS performs the copy itself, with its own
///    rights, and labels the button "Сохранить" because that is what is
///    happening.
///  * `pickFolders` is the old folders-only browse, kept for callers that
///    genuinely want a directory and nothing else.
///
/// The other half is access. A location outside the app's container is not
/// readable just because the user pointed at it: the URL arrives
/// security-scoped and stays unreadable until
/// `startAccessingSecurityScopedResource` opens it — `Directory.list()` would
/// otherwise see an empty folder, which is exactly how "I picked it and
/// nothing was sent" happens. Scopes stay open until the next pick replaces
/// them, because the session that reads those files runs long after this call
/// returns: indexing first, then serving every byte over the wire.
public class FolderPickerPlugin: NSObject {
  /// What the picker was opened for, which is all the delegate needs to know.
  private enum Mode {
    case browse
    case export
  }

  private var pending: FlutterResult?
  private var mode: Mode = .browse
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
      presentBrowser(foldersOnly: true, result: result)
    case "pickItems":
      presentBrowser(foldersOnly: false, result: result)
    case "exportItems":
      let paths = (call.arguments as? [String: Any])?["paths"] as? [String] ?? []
      presentExport(paths: paths, result: result)
    case "releaseFolders":
      releaseScopes()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Browses for folders, or — the ordinary case — for anything at all.
  ///
  /// A folder is an item too, so listing both is what makes folders
  /// tick-selectable alongside files rather than only enterable.
  private func presentBrowser(foldersOnly: Bool, result: @escaping FlutterResult) {
    guard let root = beginPresenting(result: result) else { return }
    mode = .browse

    let picker: UIDocumentPickerViewController
    if #available(iOS 14.0, *) {
      let types: [UTType] = foldersOnly ? [.folder] : [.folder, .item]
      picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
    } else {
      let types = foldersOnly
        ? [kUTTypeFolder as String]
        : [kUTTypeFolder as String, kUTTypeItem as String]
      picker = UIDocumentPickerViewController(documentTypes: types, in: .open)
    }
    picker.allowsMultipleSelection = true
    present(picker, from: root)
  }

  /// Hands the files to iOS and lets it write them where the user says.
  ///
  /// The app never touches the destination, which is the point: a folder the
  /// user picks in *open* mode is not writable from inside the sandbox, and
  /// copying into it failed every time. Here the copy is the system's, so it
  /// works wherever the user can browse to — iCloud Drive, a connected
  /// server, another app's container.
  private func presentExport(paths: [String], result: @escaping FlutterResult) {
    let urls = paths.map { URL(fileURLWithPath: $0) }
    guard !urls.isEmpty else {
      result([String]())
      return
    }
    guard let root = beginPresenting(result: result) else { return }
    mode = .export

    let picker: UIDocumentPickerViewController
    if #available(iOS 14.0, *) {
      picker = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
    } else {
      picker = UIDocumentPickerViewController(urls: urls, in: .exportToService)
    }
    present(picker, from: root)
  }

  /// Claims the single in-flight slot, or fails the call rather than dropping
  /// a caller that would then wait forever.
  private func beginPresenting(result: @escaping FlutterResult) -> UIViewController? {
    guard pending == nil else {
      result(FlutterError(code: "BUSY", message: "a picker is already open", details: nil))
      return nil
    }
    guard let root = Self.topViewController() else {
      result(FlutterError(code: "NO_WINDOW", message: "nothing to present from", details: nil))
      return nil
    }
    pending = result
    return root
  }

  private func present(_ picker: UIDocumentPickerViewController, from root: UIViewController) {
    picker.delegate = self
    picker.modalPresentationStyle = .formSheet
    // A sheet dragged down dismisses without going through the delegate on
    // some iOS versions, and the Dart side then waits on a result that never
    // comes — the picker screen sits there with every button dead. The
    // presentation controller reports that dismissal, so it is answered like
    // any other cancellation.
    picker.presentationController?.delegate = self
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

  private func finish(_ paths: [String]) {
    pending?(paths)
    pending = nil
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
    // Exported copies live where the user put them and are the system's
    // business, not ours: no scope to hold, nothing to read back. Reporting
    // the paths is only so the screen can say where things went.
    if mode == .export {
      finish(urls.map { $0.path })
      return
    }

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

    finish(paths)
  }

  public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    finish([String]())
  }
}

extension FolderPickerPlugin: UIAdaptivePresentationControllerDelegate {
  public func presentationControllerDidDismiss(_ controller: UIPresentationController) {
    // Only fires for a swipe-away; a tap on Cancel has already answered and
    // cleared `pending`, so this is a no-op in that case.
    guard pending != nil else { return }
    finish([String]())
  }
}
