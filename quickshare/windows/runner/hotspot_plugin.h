#ifndef RUNNER_HOTSPOT_PLUGIN_H_
#define RUNNER_HOTSPOT_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <string>
#include <variant>

namespace directdrop {

// Raises a Wi-Fi network other devices can join, and answers questions about
// the one this machine is on.
//
// Windows is the only desktop platform that can host from inside an app, which
// makes it the answer for every pair an iPhone or a Mac is half of: neither of
// those can create a network, so somebody else has to.
//
// Built on Wi-Fi Direct in *legacy* mode rather than the Mobile Hotspot API.
// The difference matters:
//
//   * `NetworkOperatorTetheringManager` shares this machine's internet
//     connection, so it needs one — a laptop with no uplink cannot use it,
//     which is exactly the situation two people in a cafe are in. It also
//     collides with the Mobile Hotspot toggle in Settings.
//   * A Wi-Fi Direct group owner with `LegacySettings` enabled is an ordinary
//     WPA2 access point as far as anything else is concerned. It needs no
//     internet, no administrator rights, and nothing in Settings. An iPhone
//     joins it the same way it joins a router.
//
// The catch is that the two cannot run at once — Windows gives Mobile Hotspot
// priority — so hosting fails while the user has that switched on, and says
// so.
class HotspotPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  HotspotPlugin();
  ~HotspotPlugin() override;

  HotspotPlugin(const HotspotPlugin&) = delete;
  HotspotPlugin& operator=(const HotspotPlugin&) = delete;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  void StartHotspot(
      const flutter::EncodableMap* arguments,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void StopHotspot(
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void ScanForNetworks(
      const flutter::EncodableMap* arguments,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void CurrentSsid(
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // Owned, not borrowed: the channel is created in RegisterWithRegistrar and
  // would otherwise be destroyed at the end of it, taking the method-call
  // handler with it and leaving a channel Dart can call into and nothing
  // answering.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;

  // Opaque so this header does not drag WinRT into every translation unit
  // that includes it.
  struct Advertisement;
  std::unique_ptr<Advertisement> advertisement_;
};

}  // namespace directdrop

#endif  // RUNNER_HOTSPOT_PLUGIN_H_
