import Flutter
import Foundation
import NetworkExtension

/// Joins the Wi-Fi network the sender raised.
///
/// iOS cannot create a hotspot from inside an app — there is no API for it, and
/// Personal Hotspot is a system toggle the user has to reach themselves. What
/// iOS *can* do is join one, which is enough: the Android or desktop side
/// hosts, the iPhone joins, and QHTP runs over the resulting LAN.
///
/// Requires the `com.apple.developer.networking.HotspotConfiguration`
/// entitlement. Without it `apply` fails at runtime with a permission error
/// while the build succeeds, so the failure is reported verbatim rather than
/// swallowed.
class HotspotBridge: NSObject {
    static let channelName = "quickshare/hotspot"

    /// Networks this app configured, so they can be removed afterwards instead
    /// of lingering in the user's Wi-Fi list.
    private var joinedSsids: Set<String> = []

    func register(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: HotspotBridge.channelName,
                                           binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self = self else { return }
            switch call.method {
            case "joinHotspot":
                self.join(call: call, result: result)
            case "startHotspot":
                result(FlutterError(
                    code: "UNSUPPORTED",
                    message: "iOS does not let an app create a Wi-Fi network. "
                        + "Host it from the Android device or turn on Personal "
                        + "Hotspot manually.",
                    details: nil))
            case "stopHotspot":
                self.leaveJoinedNetworks()
                result(nil)
            default:
                result(FlutterMethodNotImplemented)
            }
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

        let configuration: NEHotspotConfiguration
        if passphrase.isEmpty {
            configuration = NEHotspotConfiguration(ssid: ssid)
        } else {
            configuration = NEHotspotConfiguration(ssid: ssid,
                                                   passphrase: passphrase,
                                                   isWEP: false)
        }

        // The network exists for one transfer. joinOnce keeps it out of the
        // user's saved networks, so their phone does not try to rejoin a
        // hotspot that stopped existing an hour ago.
        configuration.joinOnce = true

        NEHotspotConfigurationManager.shared.apply(configuration) { [weak self] error in
            if let error = error as NSError? {
                // "already associated" means we are on the right network
                // already, which is success as far as the caller cares.
                if error.code == NEHotspotConfigurationError.alreadyAssociated.rawValue {
                    self?.joinedSsids.insert(ssid)
                    result(nil)
                    return
                }
                result(FlutterError(
                    code: "JOIN_FAILED",
                    message: self?.describe(error: error) ?? error.localizedDescription,
                    details: nil))
                return
            }
            self?.joinedSsids.insert(ssid)
            result(nil)
        }
    }

    private func describe(error: NSError) -> String {
        switch error.code {
        case NEHotspotConfigurationError.userDenied.rawValue:
            return "You declined the request to join the network."
        case NEHotspotConfigurationError.invalidWPAPassphrase.rawValue:
            return "The network password from the sender was not accepted."
        case NEHotspotConfigurationError.pending.rawValue:
            return "A previous join request is still in progress."
        case NEHotspotConfigurationError.systemConfiguration.rawValue:
            return "A configuration profile on this device controls Wi-Fi and "
                + "blocks joining networks from apps."
        case NEHotspotConfigurationError.unsupported.rawValue:
            return "This device or iOS version cannot join networks from an app."
        default:
            return "Could not join the network: \(error.localizedDescription)"
        }
    }

    private func leaveJoinedNetworks() {
        for ssid in joinedSsids {
            NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
        }
        joinedSsids.removeAll()
    }
}
