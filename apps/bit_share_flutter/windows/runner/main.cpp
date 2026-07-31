#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <ShObjIdl_core.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

// A stable identity prevents Windows from grouping Bit-Share with the generic
// Flutter runner or reusing a pinned Flutter taskbar icon.
constexpr wchar_t kBitShareAppUserModelId[] = L"com.bitstation.bitshare";

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Must be set before creating a window so the taskbar resolves Bit-Share's
  // own icon and never the Flutter runner identity.
  SetCurrentProcessExplicitAppUserModelID(kBitShareAppUserModelId);

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Bit-Share", origin, size)) {
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
