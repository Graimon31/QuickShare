import Cocoa
import FlutterMacOS

/// Keeps a user-chosen save folder writable across app restarts, under the
/// sandbox.
///
/// Picking a folder through `file_picker`'s NSOpenPanel grants this sandboxed
/// app write access to it — but only for the current process. The path
/// string alone remembers nothing; the next launch has no more permission to
/// write there than to any other folder outside the container. A
/// security-scoped bookmark is Apple's answer: opaque data captured while
/// access is live, which can be resolved back into a working URL — with
/// access re-granted — in a future launch. This is the same mechanism Xcode,
/// Finder-adjacent apps, and every sandboxed app with a "remember this
/// folder" setting relies on.
///
/// Two calls bracket every use: `startAccessing` resolves the bookmark and
/// opens the scope, the caller does its file writes, then `stopAccessing`
/// closes it. Holding the scope open indefinitely rather than pairing the
/// two is exactly what Apple's own documentation warns against.
public class SaveLocationPlugin: NSObject {
  private var activeScopedURL: URL?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "quickshare/save_location",
      binaryMessenger: registrar.messenger
    )
    let instance = SaveLocationPlugin()
    channel.setMethodCallHandler { call, result in
      instance.handle(call, result: result)
    }
    objc_setAssociatedObject(channel, "save_location.instance", instance, .OBJC_ASSOCIATION_RETAIN)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "createBookmark":
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String else {
        result(FlutterError(code: "BAD_ARGS", message: "path required", details: nil))
        return
      }
      result(createBookmark(path: path))

    case "startAccessing":
      guard let args = call.arguments as? [String: Any],
            let bookmark = args["bookmark"] as? String else {
        result(FlutterError(code: "BAD_ARGS", message: "bookmark required", details: nil))
        return
      }
      result(startAccessing(base64Bookmark: bookmark))

    case "stopAccessing":
      stopAccessing()
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Captures the sandbox extension the picker just granted, while it is
  /// still live. Called immediately after `file_picker` returns the chosen
  /// path — waiting even one Flutter frame risks the transient grant having
  /// already lapsed.
  private func createBookmark(path: String) -> Any {
    let url = URL(fileURLWithPath: path)
    do {
      let data = try url.bookmarkData(
        options: .withSecurityScope,
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
      return data.base64EncodedString()
    } catch {
      return FlutterError(
        code: "BOOKMARK_FAILED",
        message: "\(error)",
        details: nil
      )
    }
  }

  /// Resolves the bookmark and opens its security scope. The returned path
  /// is only genuinely writable while the scope stays open — until the
  /// matching `stopAccessing`.
  private func startAccessing(base64Bookmark: String) -> Any {
    guard let data = Data(base64Encoded: base64Bookmark) else {
      return FlutterError(code: "BAD_BOOKMARK", message: "not valid base64", details: nil)
    }

    do {
      var isStale = false
      let url = try URL(
        resolvingBookmarkData: data,
        options: .withSecurityScope,
        relativeTo: nil,
        bookmarkDataIsStale: &isStale
      )

      guard url.startAccessingSecurityScopedResource() else {
        return FlutterError(
          code: "ACCESS_DENIED",
          message: "startAccessingSecurityScopedResource returned false for \(url.path)",
          details: nil
        )
      }

      // One folder at a time is all this app ever needs; closing a previous
      // scope before opening a new one avoids leaking them across repeated
      // settings changes within one run.
      if let previous = activeScopedURL, previous != url {
        previous.stopAccessingSecurityScopedResource()
      }
      activeScopedURL = url

      return [
        "path": url.path,
        // A stale bookmark still resolves and still grants access this time
        // — the folder moved or was renamed since the bookmark was made, and
        // the caller should mint a fresh one now that it has a working path,
        // rather than fail a save that would otherwise succeed.
        "stale": isStale,
      ]
    } catch {
      return FlutterError(
        code: "RESOLVE_FAILED",
        message: "\(error)",
        details: nil
      )
    }
  }

  private func stopAccessing() {
    activeScopedURL?.stopAccessingSecurityScopedResource()
    activeScopedURL = nil
  }
}
