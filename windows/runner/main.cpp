#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

constexpr wchar_t kSingleInstanceMutex[] =
    L"Local\\HarborProxy.Desktop.SingleInstance";

void ActivateExistingWindow() {
  // The first process may still be creating its Flutter window. Retry briefly
  // so a second launch never appears to do nothing.
  for (int attempt = 0; attempt < 20; ++attempt) {
    HWND existing = ::FindWindow(kHarborProxyWindowClassName, nullptr);
    if (existing != nullptr) {
      if (::IsIconic(existing)) {
        ::ShowWindowAsync(existing, SW_RESTORE);
      } else {
        ::ShowWindowAsync(existing, SW_SHOW);
      }
      ::SetForegroundWindow(existing);
      ::FlashWindow(existing, TRUE);
      return;
    }
    ::Sleep(50);
  }
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  HANDLE single_instance =
      ::CreateMutex(nullptr, FALSE, kSingleInstanceMutex);
  if (single_instance == nullptr) {
    if (::GetLastError() == ERROR_ACCESS_DENIED) {
      // A differently elevated instance owns the mutex. We still can locate
      // and restore its top-level window instead of failing silently.
      ActivateExistingWindow();
      return EXIT_SUCCESS;
    }
    return EXIT_FAILURE;
  }
  if (::GetLastError() == ERROR_ALREADY_EXISTS) {
    ActivateExistingWindow();
    ::CloseHandle(single_instance);
    return EXIT_SUCCESS;
  }

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
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"HarborProxy", origin, size)) {
    ::CloseHandle(single_instance);
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  ::CloseHandle(single_instance);
  return EXIT_SUCCESS;
}
