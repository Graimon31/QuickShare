#include "hotspot_plugin.h"

#include <windows.h>
#include <wlanapi.h>

// unknwn.h has to come before any C++/WinRT header: winrt/base.h keys its
// COM interop off whether IUnknown is already declared, and including it
// afterwards is the classic way to get a wall of errors out of the projection
// rather than out of your own code.
#include <unknwn.h>

#include <winrt/Windows.Devices.WiFiDirect.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Security.Credentials.h>
#include <winrt/base.h>

#include <algorithm>
#include <set>
#include <string>
#include <vector>

namespace directdrop {

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

using winrt::Windows::Devices::WiFiDirect::WiFiDirectAdvertisementPublisher;
using winrt::Windows::Devices::WiFiDirect::
    WiFiDirectAdvertisementPublisherStatus;
using winrt::Windows::Security::Credentials::PasswordCredential;

constexpr char kChannelName[] = "quickshare/hotspot";

std::string ToUtf8(const std::wstring& wide) {
  if (wide.empty()) return {};
  const int size = WideCharToMultiByte(CP_UTF8, 0, wide.data(),
                                       static_cast<int>(wide.size()), nullptr,
                                       0, nullptr, nullptr);
  std::string out(size, 0);
  WideCharToMultiByte(CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()),
                      out.data(), size, nullptr, nullptr);
  return out;
}

std::wstring ToWide(const std::string& utf8) {
  if (utf8.empty()) return {};
  const int size = MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                                       static_cast<int>(utf8.size()), nullptr, 0);
  std::wstring out(size, 0);
  MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                      out.data(), size);
  return out;
}

const std::string* StringArgument(const EncodableMap* arguments,
                                  const char* key) {
  if (!arguments) return nullptr;
  const auto it = arguments->find(EncodableValue(key));
  if (it == arguments->end()) return nullptr;
  return std::get_if<std::string>(&it->second);
}

// The profile XML takes the SSID twice — as text and as bytes — and a
// passphrase; all three can carry what the other device picked, so the text
// is escaped and the bytes are hex.
std::string XmlEscape(const std::string& value) {
  std::string out;
  out.reserve(value.size());
  for (const char c : value) {
    switch (c) {
      case '&': out += "&amp;"; break;
      case '<': out += "&lt;"; break;
      case '>': out += "&gt;"; break;
      case '"': out += "&quot;"; break;
      case '\'': out += "&apos;"; break;
      default: out += c;
    }
  }
  return out;
}

std::string ToHex(const std::string& bytes) {
  static constexpr char kDigits[] = "0123456789ABCDEF";
  std::string out;
  out.reserve(bytes.size() * 2);
  for (const unsigned char c : bytes) {
    out += kDigits[c >> 4];
    out += kDigits[c & 0x0F];
  }
  return out;
}

// Every SSID this machine can currently see, and the one it is joined to.
//
// The Native WiFi API rather than WinRT: `WlanGetAvailableNetworkList` reports
// what is in range in one call, where the WinRT WiFiAdapter equivalent is
// asynchronous and needs a capability declaration this app does not otherwise
// carry.
struct WlanSnapshot {
  std::set<std::string> ssids;
  std::string connected;
  bool queried = false;
};

WlanSnapshot ReadWlan() {
  WlanSnapshot snapshot;

  DWORD negotiated = 0;
  HANDLE client = nullptr;
  if (WlanOpenHandle(2, nullptr, &negotiated, &client) != ERROR_SUCCESS) {
    return snapshot;
  }

  WLAN_INTERFACE_INFO_LIST* interfaces = nullptr;
  if (WlanEnumInterfaces(client, nullptr, &interfaces) != ERROR_SUCCESS) {
    WlanCloseHandle(client, nullptr);
    return snapshot;
  }

  for (DWORD i = 0; i < interfaces->dwNumberOfItems; i++) {
    const GUID& guid = interfaces->InterfaceInfo[i].InterfaceGuid;

    WLAN_AVAILABLE_NETWORK_LIST* networks = nullptr;
    if (WlanGetAvailableNetworkList(client, &guid, 0, nullptr, &networks) ==
        ERROR_SUCCESS) {
      snapshot.queried = true;
      for (DWORD n = 0; n < networks->dwNumberOfItems; n++) {
        const auto& network = networks->Network[n];
        if (network.dot11Ssid.uSSIDLength == 0) continue;
        // The SSID is bytes, not a string: it is not NUL-terminated and is
        // only conventionally UTF-8.
        snapshot.ssids.emplace(
            reinterpret_cast<const char*>(network.dot11Ssid.ucSSID),
            network.dot11Ssid.uSSIDLength);
        if (network.dwFlags & WLAN_AVAILABLE_NETWORK_CONNECTED) {
          snapshot.connected.assign(
              reinterpret_cast<const char*>(network.dot11Ssid.ucSSID),
              network.dot11Ssid.uSSIDLength);
        }
      }
      WlanFreeMemory(networks);
    }
  }

  WlanFreeMemory(interfaces);
  WlanCloseHandle(client, nullptr);
  return snapshot;
}

}  // namespace

// Holds the publisher for as long as the network is up. Closing it is what
// takes the network down, so it cannot be a local.
struct HotspotPlugin::Advertisement {
  WiFiDirectAdvertisementPublisher publisher{nullptr};
  std::string ssid;
  std::string passphrase;
};

// static
void HotspotPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto channel =
      std::make_unique<flutter::MethodChannel<EncodableValue>>(
          registrar->messenger(), kChannelName,
          &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<HotspotPlugin>();
  channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto& call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });
  plugin->channel_ = std::move(channel);

  registrar->AddPlugin(std::move(plugin));
}

HotspotPlugin::HotspotPlugin() = default;

HotspotPlugin::~HotspotPlugin() {
  DeleteTemporaryProfile();
  // A network that outlives the app is a network nobody can turn off from
  // inside it.
  if (advertisement_ && advertisement_->publisher) {
    try {
      advertisement_->publisher.Stop();
    } catch (...) {
      // Shutting down; there is nowhere to report this.
    }
  }
}

void HotspotPlugin::HandleMethodCall(
    const flutter::MethodCall<EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const auto* arguments = std::get_if<EncodableMap>(call.arguments());

  if (call.method_name() == "startHotspot") {
    StartHotspot(arguments, std::move(result));
  } else if (call.method_name() == "stopHotspot") {
    StopHotspot(std::move(result));
  } else if (call.method_name() == "scanForNetworks") {
    ScanForNetworks(arguments, std::move(result));
  } else if (call.method_name() == "currentSsid") {
    CurrentSsid(std::move(result));
  } else if (call.method_name() == "joinHotspot") {
    JoinHotspot(arguments, std::move(result));
  } else if (call.method_name() == "leaveHotspot") {
    DeleteTemporaryProfile();
    result->Success();
  } else {
    result->NotImplemented();
  }
}

void HotspotPlugin::StartHotspot(
    const EncodableMap* arguments,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const std::string* ssid = StringArgument(arguments, "ssid");
  const std::string* passphrase = StringArgument(arguments, "passphrase");

  if (!ssid || ssid->empty()) {
    result->Error("BAD_ARGS", "startHotspot needs an ssid");
    return;
  }
  // WPA2 refuses anything shorter, and finding that out as a driver error
  // helps nobody.
  if (!passphrase || passphrase->size() < 8) {
    result->Error("BAD_ARGS",
                  "startHotspot needs a passphrase of at least 8 characters");
    return;
  }

  if (advertisement_ && advertisement_->publisher) {
    result->Error("ALREADY_RUNNING", "A network is already up");
    return;
  }

  try {
    auto advertisement = std::make_unique<Advertisement>();
    advertisement->ssid = *ssid;
    advertisement->passphrase = *passphrase;
    advertisement->publisher = WiFiDirectAdvertisementPublisher();

    auto settings = advertisement->publisher.Advertisement().LegacySettings();
    settings.IsEnabled(true);
    settings.Ssid(winrt::hstring(ToWide(*ssid)));

    PasswordCredential credential;
    credential.Password(winrt::hstring(ToWide(*passphrase)));
    settings.Passphrase(credential);

    // Without this Windows waits to be invited into somebody else's group
    // instead of forming its own, and nothing ever appears in the air.
    advertisement->publisher.Advertisement().IsAutonomousGroupOwnerEnabled(
        true);

    advertisement->publisher.Start();

    // Start() is asynchronous in effect: the status tells you whether the
    // radio actually took it. Aborted almost always means Mobile Hotspot is
    // switched on in Settings, which Windows gives priority over this.
    const auto status = advertisement->publisher.Status();
    if (status == WiFiDirectAdvertisementPublisherStatus::Aborted) {
      result->Error(
          "START_FAILED",
          "Windows refused to create the network. If Mobile Hotspot is on in "
          "Settings, turn it off — the two cannot run at the same time.");
      return;
    }

    advertisement_ = std::move(advertisement);

    EncodableMap credentials;
    credentials[EncodableValue("ssid")] = EncodableValue(*ssid);
    credentials[EncodableValue("passphrase")] = EncodableValue(*passphrase);
    // The address arrives once a client associates; the Dart side polls the
    // interface list for it, exactly as it does on Android.
    result->Success(EncodableValue(credentials));
  } catch (const winrt::hresult_error& error) {
    result->Error("START_FAILED", ToUtf8(std::wstring(error.message())));
  } catch (...) {
    result->Error("START_FAILED", "Could not create the network");
  }
}

void HotspotPlugin::StopHotspot(
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  DeleteTemporaryProfile();
  if (!advertisement_ || !advertisement_->publisher) {
    result->Success();
    return;
  }

  try {
    advertisement_->publisher.Stop();
  } catch (const winrt::hresult_error&) {
    // Already gone. Nothing a caller on the way out of a transfer can do.
  }
  advertisement_.reset();
  result->Success();
}

void HotspotPlugin::ScanForNetworks(
    const EncodableMap* arguments,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const std::string* prefix = StringArgument(arguments, "prefix");
  const WlanSnapshot snapshot = ReadWlan();

  if (!snapshot.queried) {
    result->Error("SCAN_FAILED",
                  "Windows would not report the nearby networks. The Wi-Fi "
                  "adapter may be off.");
    return;
  }

  EncodableList found;
  for (const auto& ssid : snapshot.ssids) {
    if (prefix && !prefix->empty() && ssid.rfind(*prefix, 0) != 0) continue;
    found.push_back(EncodableValue(ssid));
  }
  result->Success(EncodableValue(found));
}

void HotspotPlugin::JoinHotspot(
    const flutter::EncodableMap* arguments,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const std::string* ssid = StringArgument(arguments, "ssid");
  const std::string* passphrase = StringArgument(arguments, "passphrase");
  if (!ssid || ssid->empty() || ssid->size() > 32) {
    result->Error("BAD_ARGS", "joinHotspot needs an ssid of at most 32 bytes");
    return;
  }
  if (!passphrase || passphrase->size() < 8 || passphrase->size() > 63) {
    result->Error("BAD_ARGS",
                  "joinHotspot needs a WPA passphrase of 8-63 characters");
    return;
  }

  DWORD negotiated = 0;
  HANDLE client = nullptr;
  if (WlanOpenHandle(2, nullptr, &negotiated, &client) != ERROR_SUCCESS) {
    result->Error("UNAVAILABLE",
                  "The Wi-Fi service is not running on this machine");
    return;
  }

  WLAN_INTERFACE_INFO_LIST* interfaces = nullptr;
  if (WlanEnumInterfaces(client, nullptr, &interfaces) != ERROR_SUCCESS ||
      interfaces->dwNumberOfItems == 0) {
    if (interfaces) WlanFreeMemory(interfaces);
    WlanCloseHandle(client, nullptr);
    result->Error("UNAVAILABLE", "This machine has no Wi-Fi adapter");
    return;
  }
  const GUID guid = interfaces->InterfaceInfo[0].InterfaceGuid;
  WlanFreeMemory(interfaces);

  // A stored profile is how WlanConnect is driven without the UI: the
  // profile names the network and carries the key, the connect call points
  // at it by name, and the association itself completes asynchronously —
  // the Dart side confirms it landed by watching currentSsid.
  const std::string xml =
      "<?xml version=\"1.0\"?>"
      "<WLANProfile xmlns=\"http://www.microsoft.com/networking/WLAN/profile/v1\">"
      "<name>" + XmlEscape(*ssid) + "</name>"
      "<SSIDConfig><SSID><hex>" + ToHex(*ssid) + "</hex><name>" +
      XmlEscape(*ssid) + "</name></SSID></SSIDConfig>"
      "<connectionType>ESS</connectionType>"
      "<connectionMode>manual</connectionMode>"
      "<MSM><security>"
      "<authEncryption><authentication>WPA2PSK</authentication>"
      "<encryption>AES</encryption><useOneX>false</useOneX></authEncryption>"
      "<sharedKey><keyType>passPhrase</keyType><protected>false</protected>"
      "<keyMaterial>" + XmlEscape(*passphrase) + "</keyMaterial></sharedKey>"
      "</security></MSM>"
      "</WLANProfile>";

  const std::wstring wide_xml = ToWide(xml);
  DWORD reason = 0;
  if (WlanSetProfile(client, &guid, 0, wide_xml.c_str(), nullptr, TRUE,
                     nullptr, &reason) != ERROR_SUCCESS) {
    // WlanReasonCodeToString writes into a caller-owned buffer and takes the
    // reason code itself — it neither allocates (no WlanFreeMemory) nor wants
    // the client handle.
    WCHAR explanation[512];
    std::string detail = "code " + std::to_string(reason);
    if (WlanReasonCodeToString(reason, 512, explanation, nullptr) ==
        ERROR_SUCCESS) {
      detail = ToUtf8(std::wstring(explanation));
    }
    WlanCloseHandle(client, nullptr);
    result->Error("JOIN_FAILED",
                  "Windows refused the network profile: " + detail);
    return;
  }

  const std::wstring profile_name = ToWide(*ssid);
  DOT11_SSID target{};
  std::copy_n(ssid->begin(), ssid->size(), target.ucSSID);
  target.uSSIDLength = static_cast<ULONG>(ssid->size());

  WLAN_CONNECTION_PARAMETERS params{};
  params.wlanConnectionMode = wlan_connection_mode_profile;
  params.strProfile = profile_name.c_str();
  params.pDot11Ssid = &target;
  params.dot11BssType = dot11_BSS_type_infrastructure;
  params.dwFlags = 0;

  const DWORD connect_result = WlanConnect(client, &guid, &params, nullptr);
  if (connect_result == ERROR_SUCCESS) {
    last_joined_ssid_ = *ssid;
    LPOLESTR guid_str = nullptr;
    if (StringFromCLSID(guid, &guid_str) == S_OK && guid_str) {
      last_joined_guid_ = ToUtf8(guid_str);
      CoTaskMemFree(guid_str);
    }
  }
  WlanCloseHandle(client, nullptr);

  if (connect_result != ERROR_SUCCESS) {
    result->Error(
        "JOIN_FAILED",
        "Windows would not start connecting (code " +
            std::to_string(connect_result) + ")");
    return;
  }
  result->Success();
}

void HotspotPlugin::DeleteTemporaryProfile() {
  if (last_joined_ssid_.empty() || last_joined_guid_.empty()) return;
  DWORD negotiated = 0;
  HANDLE client = nullptr;
  if (WlanOpenHandle(2, nullptr, &negotiated, &client) == ERROR_SUCCESS) {
    GUID guid{};
    const std::wstring wide_guid = ToWide(last_joined_guid_);
    if (CLSIDFromString(wide_guid.c_str(), &guid) == NOERROR) {
      const std::wstring profile_name = ToWide(last_joined_ssid_);
      WlanDeleteProfile(client, &guid, profile_name.c_str(), nullptr);
    }
    WlanCloseHandle(client, nullptr);
  }
  last_joined_ssid_.clear();
  last_joined_guid_.clear();
}

void HotspotPlugin::CurrentSsid(
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const WlanSnapshot snapshot = ReadWlan();
  if (snapshot.connected.empty()) {
    result->Success();
    return;
  }
  result->Success(EncodableValue(snapshot.connected));
}

}  // namespace directdrop
