#include "include/tal_drag_preview/tal_drag_preview_plugin.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <memory>
#include <optional>

namespace {

class TalDragPreviewPlugin : public flutter::Plugin {
 public:
  explicit TalDragPreviewPlugin(flutter::PluginRegistrarWindows* registrar)
      : registrar_(registrar) {
    window_proc_id_ = registrar_->RegisterTopLevelWindowProcDelegate(
        [this](HWND hwnd, UINT message, WPARAM wparam,
               LPARAM lparam) -> std::optional<LRESULT> {
          return HandleWindowMessage(hwnd, message, wparam, lparam);
        });
    RestoreForegroundFocusAfterCreation();
  }

  ~TalDragPreviewPlugin() override {
    registrar_->UnregisterTopLevelWindowProcDelegate(window_proc_id_);
  }

  void SetClickThrough(bool enabled) {
    const HWND window = GetRootWindow();
    LONG_PTR style = GetWindowLongPtr(window, GWL_EXSTYLE);
    if (enabled) {
      style |= WS_EX_TRANSPARENT | WS_EX_NOACTIVATE;
    } else {
      style &= ~(WS_EX_TRANSPARENT | WS_EX_NOACTIVATE);
    }
    SetWindowLongPtr(window, GWL_EXSTYLE, style);
    SetWindowPos(window, nullptr, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE |
                     SWP_FRAMECHANGED);
  }

  void ShowInactiveAt(double x, double y, double scale) {
    SetWindowPos(GetRootWindow(), HWND_TOPMOST, static_cast<int>(x * scale),
                 static_cast<int>(y * scale), 0, 0,
                 SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
  }

 private:
  HWND GetRootWindow() const {
    return GetAncestor(registrar_->GetView()->GetNativeWindow(), GA_ROOT);
  }

  std::optional<LRESULT> HandleWindowMessage(HWND hwnd, UINT message,
                                             WPARAM wparam, LPARAM lparam) {
    if (hwnd != GetRootWindow()) return std::nullopt;
    const bool preview =
        (GetWindowLongPtr(hwnd, GWL_EXSTYLE) & WS_EX_NOACTIVATE) != 0;
    switch (message) {
      case WM_WINDOWPOSCHANGING: {
        auto* position = reinterpret_cast<WINDOWPOS*>(lparam);
        if (preview ||
            (!IsWindowVisible(hwnd) && !(position->flags & SWP_SHOWWINDOW))) {
          position->flags |= SWP_NOACTIVATE;
        }
        break;
      }
      case WM_ACTIVATE:
        // desktop_multi_window otherwise focuses even deactivated or hidden
        // windows. Both previews and idle detached windows must remain inert.
        if (LOWORD(wparam) == WA_INACTIVE || preview ||
            !IsWindowVisible(hwnd)) {
          return 0;
        }
        break;
      case WM_SETFOCUS:
        if (!preview && IsWindowVisible(hwnd) &&
            GetForegroundWindow() == hwnd) {
          SetFocus(registrar_->GetView()->GetNativeWindow());
          return 0;
        }
        break;
    }
    return std::nullopt;
  }

  void RestoreForegroundFocusAfterCreation() {
    // desktop_multi_window focuses its child view before registering plugins,
    // even for hidden windows. Restore the foreground Flutter view on this
    // thread without activating another application.
    const HWND view = registrar_->GetView()->GetNativeWindow();
    const HWND window = GetRootWindow();
    const HWND foreground = GetForegroundWindow();
    if (!IsWindowVisible(window) && GetFocus() == view &&
        foreground != nullptr && foreground != window &&
        GetWindowThreadProcessId(foreground, nullptr) == GetCurrentThreadId()) {
      const HWND foreground_view =
          FindWindowEx(foreground, nullptr, L"FLUTTERVIEW", nullptr);
      if (foreground_view != nullptr) SetFocus(foreground_view);
    }
  }

  flutter::PluginRegistrarWindows* registrar_;
  int window_proc_id_ = -1;
};

}  // namespace

void TalDragPreviewPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar_ref) {
  auto* registrar =
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar_ref);
  auto plugin = std::make_unique<TalDragPreviewPlugin>(registrar);
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "take_a_look/drag_preview_window",
          &flutter::StandardMethodCodec::GetInstance());
  auto* plugin_ptr = plugin.get();
  channel->SetMethodCallHandler([plugin_ptr](const auto& call, auto result) {
    if (call.method_name() != "setClickThrough" &&
        call.method_name() != "showInactiveAt") {
      result->NotImplemented();
      return;
    }
    const auto* arguments =
        std::get_if<flutter::EncodableMap>(call.arguments());
    if (arguments == nullptr) {
      result->Error("invalid_arguments", "Expected an argument map");
      return;
    }
    if (call.method_name() == "showInactiveAt") {
      const auto x = arguments->find(flutter::EncodableValue("x"));
      const auto y = arguments->find(flutter::EncodableValue("y"));
      const auto scale =
          arguments->find(flutter::EncodableValue("devicePixelRatio"));
      if (x == arguments->end() || y == arguments->end() ||
          scale == arguments->end() ||
          !std::holds_alternative<double>(x->second) ||
          !std::holds_alternative<double>(y->second) ||
          !std::holds_alternative<double>(scale->second) ||
          std::get<double>(scale->second) <= 0) {
        result->Error("invalid_arguments", "Expected coordinates and scale");
        return;
      }
      plugin_ptr->ShowInactiveAt(std::get<double>(x->second),
                                 std::get<double>(y->second),
                                 std::get<double>(scale->second));
      result->Success();
      return;
    }
    const auto iterator = arguments->find(flutter::EncodableValue("enabled"));
    if (iterator == arguments->end() ||
        !std::holds_alternative<bool>(iterator->second)) {
      result->Error("invalid_arguments", "Expected enabled boolean");
      return;
    }
    plugin_ptr->SetClickThrough(std::get<bool>(iterator->second));
    result->Success();
  });
  registrar->AddPlugin(std::move(plugin));
}
