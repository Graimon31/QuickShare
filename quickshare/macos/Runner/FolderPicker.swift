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
    DiskSpacePlugin.register(with: registrar)
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

/// How much room a volume has, for the receiver to check before it starts.
///
/// `volumeAvailableCapacityForImportantUsageKey` rather than the plain
/// "available" figure: it is the number Finder, Settings and the system's own
/// "is there room for this download?" checks use, and it counts space the
/// system will give back on demand (purgeable caches) that the plain figure
/// reports as used. It is sometimes 0 or absent for volumes that do not track
/// purgeable space — network shares, some external disks — and then the plain
/// figure is the honest answer. If neither is there, or both are 0, the call
/// fails, and Dart treats a failed call as "unknown", never as "plenty" and
/// never as "none".
///
/// The `disk_space_2` plugin this replaces crashed while registering on iOS
/// 18.4.1; this is a plain method channel with no registration of its own to
/// get wrong. Registered by [FolderPickerPlugin] so it needs no project-file
/// change of its own.
public class DiskSpacePlugin: NSObject {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "quickshare/disk_space",
      binaryMessenger: registrar.messenger
    )
    let instance = DiskSpacePlugin()
    channel.setMethodCallHandler { call, result in
      instance.handle(call, result: result)
    }
    objc_setAssociatedObject(channel, "disk_space.instance", instance, .OBJC_ASSOCIATION_RETAIN)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "availableBytes":
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String else {
        result(FlutterError(code: "BAD_ARGS", message: "path required", details: nil))
        return
      }
      // Off the platform thread. Asking about a volume that has gone away — a
      // stale network mount, a disk pulled while the app was running — can
      // hold a file-system call for a long time, and this is the thread the
      // whole UI waits on. The answer is worked out on a background queue and
      // handed back on the main one, which is where Flutter wants a result.
      DispatchQueue.global(qos: .userInitiated).async {
        let answer = self.availableBytes(at: path)
        DispatchQueue.main.async { result(answer) }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// The destination may not exist yet — the receiver creates it as files
  /// arrive — so the question is asked about the nearest folder that does.
  private func availableBytes(at path: String) -> Any {
    var url = URL(fileURLWithPath: path)
    while !FileManager.default.fileExists(atPath: url.path) && url.path != "/" {
      url = url.deletingLastPathComponent()
    }
    do {
      let values = try url.resourceValues(forKeys: [
        .volumeAvailableCapacityForImportantUsageKey,
        .volumeAvailableCapacityKey,
      ])
      let important = values.volumeAvailableCapacityForImportantUsage ?? 0
      if important > 0 {
        return NSNumber(value: important)
      }
      let plain = Int64(values.volumeAvailableCapacity ?? 0)
      if plain > 0 {
        return NSNumber(value: plain)
      }
      // Neither figure says there is any room. On a volume that does not track
      // free space that is "I do not know", not "none": answering a known 0
      // would make Dart refuse every transfer to it. An error is read as
      // unknown, the transfer runs, and a disk that really is full says so
      // when the write fails.
      return FlutterError(
        code: "UNAVAILABLE",
        message: "the volume reports no free space (important usage \(important), plain \(plain))",
        details: nil)
    } catch {
      return FlutterError(code: "UNAVAILABLE", message: "\(error)", details: nil)
    }
  }
}
