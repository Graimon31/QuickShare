#include "hotspot_plugin.h"

#include <windows.h>
#include <wlanapi.h>

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
  winrt::event_token status_token{};
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

  registrar->AddPlugin(std::move(plugin));
}

HotspotPlugin::HotspotPlugin() = default;

HotspotPlugin::~HotspotPlugin() {
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
    // Windows joins networks through its own UI. Automating that means
    // writing a WLAN profile and calling WlanConnect, which is a bigger piece
    // than it looks and is not what unblocks anything: in every pair Windows
    // is in, Windows is the one that can host.
    result->Error("UNSUPPORTED",
                  "Joining from inside the app is not implemented on Windows; "
                  "this machine can host the network instead.");
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
