import CoreLocation
import CoreWLAN
import Foundation
import FlutterMacOS

/// Joins the network another device raised, and lists the ones in range.
///
/// The Mac is always the guest, never the host. Raising an access point is
/// Internet Sharing, and Apple has said plainly there is no supported API for
/// it — the private `startHostAPMode` behind it needs an entitlement no third
/// party is given, sandbox or not. So `startHotspot` here refuses rather than
/// pretending: the Android or Windows side hosts, and this side joins.
///
/// Joining, by contrast, is public API and always has been:
/// `CWInterface.associate(to:password:)`.
///
/// ## Scanning, and why it needs Location Services
///
/// `scanForNetworks` is what lets two desktops find each other with no camera
/// between them: the network a host raises is visible in the air before anyone
/// joins it, so a Mac can list the `DirectDrop-…` networks around it and
/// present them as devices.
///
/// From macOS 14 this is location data as far as the system is concerned — a
/// list of nearby networks locates you, and Apple gates it accordingly. What
/// makes it treacherous is the shape of the refusal: `scanForNetworks` returns
/// an **empty array** and `ssid()` returns **nil**, with no error at all. On a
/// machine plainly connected to Wi-Fi it looks exactly like an empty room, and
/// a test that only checks "did it throw" passes while the feature does
/// nothing. `networksetup -getairportnetwork` shows the same blank, which is
/// how this was confirmed rather than guessed.
///
/// So authorisation is asked for explicitly, and its state is reported to Dart
/// so the UI can tell "nobody is here" from "macOS is not letting us look".
public class HotspotBridge: NSObject {
    private static let channelName = "quickshare/hotspot"

    /// Both calls into CoreWLAN block until the radio answers, which is
    /// hundreds of milliseconds for a join and seconds for a scan. On the main
    /// thread that is a frozen window.
    private let queue = DispatchQueue(label: "quickshare.hotspot", qos: .userInitiated)

    /// What the Mac was on before we moved it, so it can be put back.
    ///
    /// Joining a transfer network means leaving the one with the internet on
    /// it. Leaving the user there afterwards — no internet, no explanation —
    /// is the kind of thing people uninstall an app over.
    private var previousSsid: String?

    /// Held for the lifetime of the bridge: a manager that goes out of scope
    /// takes its pending authorisation callback with it.
    private let location = CLLocationManager()

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = HotspotBridge()
        let channel = FlutterMethodChannel(name: channelName,
                                           binaryMessenger: registrar.messenger)
        channel.setMethodCallHandler { call, result in
            instance.handle(call: call, result: result)
        }
    }

    private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "joinHotspot":
            join(call: call, result: result)
        case "scanForNetworks":
            scan(call: call, result: result)
        case "currentSsid":
            result(CWWiFiClient.shared().interface()?.ssid())
        case "locationAuthorization":
            result(authorizationName())
        case "requestLocationAccess":
            location.requestWhenInUseAuthorization()
            result(authorizationName())
        case "startHotspot":
            result(FlutterError(
                code: "UNSUPPORTED",
                message: "macOS has no API for creating a Wi-Fi network from "
                    + "an app. Host it from the Android or Windows device.",
                details: nil))
        case "stopHotspot":
            rejoinPrevious(result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func join(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let ssid = args["ssid"] as? String, !ssid.isEmpty else {
            result(FlutterError(code: "BAD_ARGS",
                                message: "joinHotspot needs an ssid",
                                details: nil))
            return
        }
        let passphrase = args["passphrase"] as? String ?? ""

        queue.async { [weak self] in
            guard let self = self else { return }
            guard let interface = CWWiFiClient.shared().interface() else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "NO_INTERFACE",
                                        message: "This Mac has no Wi-Fi interface.",
                                        details: nil))
                }
                return
            }

            if interface.ssid() == ssid {
                // Already there. The caller only cares that we are on it.
                DispatchQueue.main.async { result(nil) }
                return
            }

            // Remember where to go back to, but only the first time: a retry
            // must not record the transfer network as "previous".
            if self.previousSsid == nil, let current = interface.ssid() {
                self.previousSsid = current
            }

            do {
                // The network was raised seconds ago, so a cached scan will not
                // have it. Scanning for the one SSID is far quicker than a full
                // sweep and is what makes it joinable at all.
                let found = try interface.scanForNetworks(withName: ssid)
                guard let network = found.first(where: { $0.ssid == ssid }) else {
                    DispatchQueue.main.async {
                        result(FlutterError(
                            code: "NOT_FOUND",
                            message: "\"\(ssid)\" is not in range. It can take a "
                                + "few seconds to appear after the other device "
                                + "creates it.",
                            details: nil))
                    }
                    return
                }
                try interface.associate(to: network, password: passphrase)
                DispatchQueue.main.async { result(nil) }
            } catch let error as NSError {
                DispatchQueue.main.async {
                    result(FlutterError(code: "JOIN_FAILED",
                                        message: self.describe(error),
                                        details: nil))
                }
            }
        }
    }

    private func scan(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let prefix = (call.arguments as? [String: Any])?["prefix"] as? String

        queue.async { [weak self] in
            guard let self = self else { return }
            guard let interface = CWWiFiClient.shared().interface() else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "NO_INTERFACE",
                                        message: "This Mac has no Wi-Fi interface.",
                                        details: nil))
                }
                return
            }

            if !self.locationGranted {
                DispatchQueue.main.async {
                    result(FlutterError(
                        code: "LOCATION_DENIED",
                        message: "macOS will not list nearby networks without "
                            + "Location Services. Allow it for DirectDrop in "
                            + "System Settings › Privacy & Security › Location "
                            + "Services — without it the list is empty even "
                            + "when devices are right here.",
                        details: nil))
                }
                return
            }

            do {
                let networks = try interface.scanForNetworks(withSSID: nil)
                let names = networks
                    .compactMap { $0.ssid }
                    .filter { prefix == nil || $0.hasPrefix(prefix!) }
                    .sorted()
                DispatchQueue.main.async { result(Array(Set(names))) }
            } catch let error as NSError {
                DispatchQueue.main.async {
                    result(FlutterError(code: "SCAN_FAILED",
                                        message: self.describe(error),
                                        details: nil))
                }
            }
        }
    }

    /// Puts the Mac back on the network it was using before the transfer.
    private func rejoinPrevious(result: @escaping FlutterResult) {
        guard let ssid = previousSsid else {
            result(nil)
            return
        }
        previousSsid = nil

        queue.async {
            guard let interface = CWWiFiClient.shared().interface() else {
                DispatchQueue.main.async { result(nil) }
                return
            }
            do {
                // No password: a network the user was already on is in the
                // system keychain, and CoreWLAN uses it.
                let found = try interface.scanForNetworks(withName: ssid)
                if let network = found.first(where: { $0.ssid == ssid }) {
                    try interface.associate(to: network, password: nil)
                }
            } catch {
                // Best effort. The user can pick their network from the menu
                // bar, and failing to do it for them is not worth an error
                // dialog on top of a transfer that just succeeded.
            }
            DispatchQueue.main.async { result(nil) }
        }
    }

    private var locationGranted: Bool {
        let status = location.authorizationStatus
        return status == .authorized || status == .authorizedAlways
    }

    private func authorizationName() -> String {
        switch location.authorizationStatus {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized, .authorizedAlways: return "granted"
        @unknown default: return "unknown"
        }
    }

    /// Turns a CoreWLAN error into something a person can act on.
    ///
    /// Raw codes rather than the `CWErr` enum: the constants are stable ABI
    /// (they are in `CoreWLANTypes.h` and have not moved in a decade), while
    /// how Swift renames the cases is not, and a build breaking on a renamed
    /// case is a worse trade than a number with its name in a comment.
    private func describe(_ error: NSError) -> String {
        guard error.domain == CWErrorDomain else { return error.localizedDescription }

        switch error.code {
        case -3930: // kCWOperationNotPermittedErr
            return "macOS refused the Wi-Fi operation. Since macOS 14 the list "
                + "of nearby networks counts as location data — allow Location "
                + "Services for this app in System Settings › Privacy & "
                + "Security, then try again."
        case -3912, // kCWChallengeFailureErr
             -3924: // kCWInvalidPMKErr
            return "The other device's network refused that password. Check the "
                + "code was typed exactly as shown."
        case -3909: // kCWAssociationDeniedErr
            return "The network refused the connection. It may already have as "
                + "many devices as it allows."
        case -3900: // kCWInvalidParameterErr
            return "The network name or password was not accepted."
        case -3905, // kCWTimeoutErr
             -3925: // kCWSupplicantTimeoutErr
            return "The Wi-Fi radio did not answer in time."
        case -3903: // kCWNotSupportedErr
            return "This Mac's Wi-Fi hardware does not support that."
        default:
            return error.localizedDescription
        }
    }
}
