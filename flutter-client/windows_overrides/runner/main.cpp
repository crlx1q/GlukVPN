// GlukVPN - Windows runner entry point (vendored override).
//
// ROUND 17: this file exists because of the empty white window.
//
// Launching the client a second time painted a blank window titled "glukvpn"
// and then showed the "GlukVPN is already running" box on top of it. The guard
// that is supposed to prevent that lives in Dart
// (lib/desktop/services/single_instance.dart), and Dart is far too late: the
// Win32 runner creates its window with WS_VISIBLE and pumps messages before the
// engine has started, so by the time main() runs there is already a window on
// screen. Dart could only ever exit *after* showing one.
//
// So the guard moved down here, ahead of window creation. A second copy now
// raises the window of the first, says so, and exits without ever creating a
// window of its own.
//
// flutter create regenerates windows/, so this is vendored and copied over the
// scaffold by the build workflow - exactly the arrangement android_overrides/
// already uses for the Android manifest.
//
// The mutex name is deliberately *not* the one Dart uses. Both guards run in
// the same process on the winning copy, and sharing a name would make the Dart
// guard see its own lock, decide it was the second copy, and exit immediately.
// The Dart guard is left in place as a fallback for builds made without this
// override (a plain `flutter run` on a developer machine).

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

constexpr wchar_t kRunnerMutex[] = L"Local\\GlukVPN.Desktop.Runner";

// Auto-reset event the Dart side arms in main_windows.dart and polls every
// 400 ms. Only the running copy knows whether it is currently showing the tray
// panel or the full window, and someone who launched the shortcut again wants
// the full window - so we ask it rather than reaching in from outside.
constexpr wchar_t kShowEvent[] = L"Local\\GlukVPN.Desktop.ShowWindow";

// Window class registered by Win32Window in the Flutter runner template.
constexpr wchar_t kWindowClass[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

// The handle is intentionally never closed: the lock has to outlive this
// function and is released by the kernel when the process ends.
bool AnotherCopyIsRunning() {
  const HANDLE mutex = ::CreateMutexW(nullptr, FALSE, kRunnerMutex);
  if (mutex == nullptr) {
    // Refusing to start because a lock could not be taken would be the wrong
    // trade: a failed guard must never stop the client from running.
    return false;
  }
  return ::GetLastError() == ERROR_ALREADY_EXISTS;
}

// Best effort, in two steps: ask the running copy to surface itself, then push
// its window forward from here in case it is not listening yet.
void SurfaceRunningCopy() {
  const HANDLE show = ::OpenEventW(EVENT_MODIFY_STATE, FALSE, kShowEvent);
  if (show != nullptr) {
    ::SetEvent(show);
    ::CloseHandle(show);
  }

  const HWND window = ::FindWindowW(kWindowClass, nullptr);
  if (window == nullptr) return;
  if (::IsIconic(window)) ::ShowWindow(window, SW_RESTORE);
  ::ShowWindow(window, SW_SHOW);
  ::SetForegroundWindow(window);
}

bool SystemIsRussian() {
  wchar_t name[LOCALE_NAME_MAX_LENGTH] = {0};
  if (::GetUserDefaultLocaleName(name, LOCALE_NAME_MAX_LENGTH) == 0) {
    return false;
  }
  return name[0] == L'r' && name[1] == L'u';
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Before anything draws. This is the whole point of the override.
  if (AnotherCopyIsRunning()) {
    SurfaceRunningCopy();
    ::MessageBoxW(
        nullptr,
        SystemIsRussian()
            ? L"GlukVPN \u0443\u0436\u0435 \u0437\u0430\u043f\u0443\u0449\u0435\u043d.\n\n"
              L"\u041e\u043a\u043d\u043e \u0430\u043a\u0442\u0438\u0432\u043d\u043e\u0439 "
              L"\u043a\u043e\u043f\u0438\u0438 \u0432\u044b\u043d\u0435\u0441\u0435\u043d\u043e "
              L"\u043d\u0430 \u043f\u0435\u0440\u0435\u0434\u043d\u0438\u0439 \u043f\u043b\u0430\u043d."
            : L"GlukVPN is already running.\n\n"
              L"The existing window has been brought to the front.",
        L"GlukVPN", MB_OK | MB_ICONINFORMATION);
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

  std::vector<std::string> command_line_arguments = GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1000, 780);
  // "GlukVPN", not the lower-case project name: this string is the taskbar and
  // Alt-Tab label, and it was reading "glukvpn".
  if (!window.Create(L"GlukVPN", origin, size)) {
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
