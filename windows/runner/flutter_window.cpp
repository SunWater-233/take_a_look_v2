#include "flutter_window.h"

#include <optional>
#include <string>

#include "desktop_multi_window/desktop_multi_window_plugin.h"
#include "flutter/generated_plugin_registrant.h"
#include "gpu_preference.h"

#ifdef TAL_WINDOW_RESIZE_DIAGNOSTICS
#include "windows_resize_trace.h"
#endif

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
#ifdef TAL_WINDOW_RESIZE_DIAGNOSTICS
  tal::resize_trace::Start();
#endif
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = tal::CreateFlutterController(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_) {
    return false;
  }
#ifdef TAL_WINDOW_RESIZE_DIAGNOSTICS
  tal::resize_trace::InstallControl(flutter_controller_->engine()->messenger(),
                                   GetHandle());
#endif
  RegisterPlugins(flutter_controller_->engine());
  DesktopMultiWindowSetWindowCreatedCallback([](void* controller) {
    auto* flutter_view_controller =
        reinterpret_cast<flutter::FlutterViewController*>(controller);
    auto* registry = flutter_view_controller->engine();
    RegisterPlugins(registry);
  });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
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
#ifdef TAL_WINDOW_RESIZE_DIAGNOSTICS
  tal::resize_trace::WindowMessage sample(hwnd, message);
#endif
  if (message == WM_CLOSE) {
    // desktop_multi_window owns prewarmed and detached engines in a static
    // manager. Destroy their native windows while the main engine and platform
    // loop are still alive, before main-window teardown unloads Flutter/IME
    // state. Hiding them through WM_CLOSE would leave those engines running.
    EnumThreadWindows(
        GetCurrentThreadId(),
        [](HWND window, LPARAM) -> BOOL {
          wchar_t window_class[128] = {};
          GetClassNameW(window, window_class, 128);
          if (std::wstring(window_class) == L"FLUTTER_MULTI_WINDOW_WIN32_WINDOW") {
            DestroyWindow(window);
          }
          return TRUE;
        },
        0);
  }
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
