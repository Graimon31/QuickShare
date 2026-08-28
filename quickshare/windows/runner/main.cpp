#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  // Cap the height at 80% of the work area: with 150% display scaling a
  // hard-coded 720 logical pixels is the screen's entire logical height, and
  // the "small" window filled the screen top to bottom.
  RECT work_area{};
  SystemParametersInfo(SPI_GETWORKAREA, 0, &work_area, 0);
  const double scale = GetDpiForSystem() / 96.0;
  const unsigned screen_logical_height =
      static_cast<unsigned>((work_area.bottom - work_area.top) / scale);
  // No std::min: windows.h's min macro would claim the name first.
  const unsigned capped = screen_logical_height * 8 / 10;
  const unsigned height = capped < 720u ? capped : 720u;
  // Phone-sized on purpose: the window frame is fixed, so this is the size
  // the app keeps.
  Win32Window::Size size(480, height);
  if (!window.Create(L"DirectDrop", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
