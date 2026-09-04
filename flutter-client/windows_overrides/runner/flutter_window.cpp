// GlukVPN - Windows runner Flutter window (vendored override).
//
// ROUND 26: this file exists because of the window that flashed on a tray-only
// start.
//
// The runner template shows the window from the engine's first-frame callback
// (SetNextFrameCallback -> Show()). That happens *after* Dart main() has run
// and decided to stay hidden, so with "Start minimised" the window was still
// painted for a moment and pulled back again. Dart cannot prevent it: its
// post-frame callbacks run before the native callback fires.
//
// window_manager's documented fix ("Hidden at launch") is to remove the Show()
// here and let Dart own the moment the window appears - which it already does
// in main_windows.dart via waitUntilReadyToShow(), for every non-hidden start.
//
// Everything else is the stock template for Flutter 3.7+ (flutter_window.h is
// unchanged). flutter create regenerates windows/, so this is vendored and
// copied over the scaffold by the build workflow, next to main.cpp.

#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // Deliberately no this->Show() on the first frame: Dart decides whether the
  // window is shown at all (see the file comment). ForceRedraw is kept so the
  // first frame is still produced promptly for the non-hidden path.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
