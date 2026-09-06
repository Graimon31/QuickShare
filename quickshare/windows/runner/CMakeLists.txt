cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "hotspot_plugin.cpp"
  "main.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# hotspot_plugin.cpp needs three things beyond the defaults.
#
# wlanapi for the nearby-network list and windowsapp for the C++/WinRT
# projection that drives Wi-Fi Direct — neither is linked by a stock runner.
#
# flutter_wrapper_plugin is the one that is easy to miss. Flutter splits its
# C++ wrapper in two: `flutter_wrapper_app` (which the runner already links)
# carries core_implementations.cc and the engine/view-controller, while
# plugin_registrar.cc goes only into `flutter_wrapper_plugin` — on the
# assumption that plugins live in their own DLLs and the app never registers
# one itself. This app does, from inside the exe, so it needs that half too;
# without it every PluginRegistrar and PluginRegistrarManager symbol is an
# unresolved external at link time.
#
# Both libraries contain core_implementations.cc, which is not a conflict:
# a static library only gives up the objects that resolve something still
# missing, and those symbols are already satisfied by flutter_wrapper_app
# above.
target_link_libraries(${BINARY_NAME} PRIVATE wlanapi windowsapp)
target_link_libraries(${BINARY_NAME} PRIVATE flutter_wrapper_plugin)

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)
