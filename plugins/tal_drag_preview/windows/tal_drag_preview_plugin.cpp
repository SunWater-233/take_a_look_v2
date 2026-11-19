#include "include/tal_drag_preview/tal_drag_preview_plugin.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>
#include <commctrl.h>
#include <directmanipulation.h>

#include <array>
#include <memory>
#include <optional>

namespace {

class PlotTrackpad {
 public:
  explicit PlotTrackpad(flutter::PluginRegistrarWindows* registrar)
      : channel_(registrar->messenger(), "take_a_look/plot_trackpad",
                 &flutter::StandardMethodCodec::GetInstance()) {
    channel_.SetMethodCallHandler(
        [this, registrar](const auto& call, auto result) {
          const auto* enabled = std::get_if<bool>(call.arguments());
          if (call.method_name() != "setCapture" || enabled == nullptr) {
            result->NotImplemented();
            return;
          }
          SetCapture(registrar->GetView()->GetNativeWindow(), *enabled);
          result->Success();
        });
  }

  ~PlotTrackpad() {
    // The engine has already detached its messenger when it deletes plugins.
    // The engine disposes the channel handler as part of its own teardown.
    SetCapture(nullptr, false);
  }

 private:
  using RegisterTouchpad = BOOL(WINAPI*)(HWND, BOOL);
  using ReadTouchpadFrame = BOOL(WINAPI*)(UINT32, UINT32*, POINTER_TOUCH_INFO*);

  static FARPROC TouchpadFunction(const char* name, WORD ordinal) {
    const HMODULE user32 = GetModuleHandleW(L"user32.dll");
    const auto function = GetProcAddress(user32, name);
    return function ? function
                    : GetProcAddress(user32, MAKEINTRESOURCEA(ordinal));
  }

  void SetCapture(HWND view, bool enabled) {
    if ((window_ != nullptr) == enabled) return;
    // Resolve at runtime so older Windows versions retain Flutter's gestures.
    // These APIs are also published as ordinal-only exports by User32.
    static const auto register_touchpad = reinterpret_cast<RegisterTouchpad>(
        TouchpadFunction("RegisterTouchpadCapableWindow", 2689));
    if (enabled) {
      if (!read_frame_ || !register_touchpad ||
          !SetWindowSubclass(view, WindowProc, 0,
                             reinterpret_cast<DWORD_PTR>(this))) {
        return;
      }
      if (!register_touchpad(view, TRUE)) {
        RemoveWindowSubclass(view, WindowProc, 0);
        return;
      }
      window_ = view;
    } else {
      RemoveWindowSubclass(window_, WindowProc, 0);
      register_touchpad(window_, FALSE);
      window_ = nullptr;
      last_frame_.reset();
    }
  }

  static LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam,
                                     LPARAM lparam, UINT_PTR, DWORD_PTR data) {
    auto* self = reinterpret_cast<PlotTrackpad*>(data);
    switch (message) {
      case WM_POINTERDOWN:
      case WM_POINTERUPDATE:
      case WM_POINTERUP:
      case WM_POINTERLEAVE:
      case WM_POINTERCAPTURECHANGED:
      case DM_POINTERHITTEST: {
        const UINT32 pointer = GET_POINTERID_WPARAM(wparam);
        POINTER_INPUT_TYPE type;
        if (!GetPointerType(pointer, &type) || type != PT_TOUCHPAD) break;
        // With raw contacts enabled, keep Flutter's Direct Manipulation from
        // interpreting the same gesture a second time.
        if (message == WM_POINTERDOWN || message == WM_POINTERUPDATE) {
          self->SendFrame(window, pointer);
        } else if (message != DM_POINTERHITTEST) {
          self->EndGesture();
        }
        return 0;
      }
      case WM_NCDESTROY:
        RemoveWindowSubclass(window, WindowProc, 0);
        self->window_ = nullptr;
        self->last_frame_.reset();
        break;
    }
    return DefSubclassProc(window, message, wparam, lparam);
  }

  void SendFrame(HWND window, UINT32 pointer) {
    std::array<POINTER_TOUCH_INFO, 2> contacts{};
    UINT32 count = static_cast<UINT32>(contacts.size());
    if (!read_frame_(pointer, &count, contacts.data()) ||
        count != contacts.size()) {
      EndGesture();
      return;
    }
    const auto& first = contacts[0].pointerInfo;
    const auto& second = contacts[1].pointerInfo;
    if (!(first.pointerFlags & POINTER_FLAG_INCONTACT) ||
        !(second.pointerFlags & POINTER_FLAG_INCONTACT)) {
      EndGesture();
      return;
    }
    if (last_frame_ == first.frameId) return;
    last_frame_ = first.frameId;

    POINT cursor = first.ptPixelLocation;
    ScreenToClient(window, &cursor);
    const double pixel_ratio = GetDpiForWindow(window) / 96.0;
    // HIMETRIC is 0.01 mm. Convert physical motion to 96-DPI logical pixels.
    constexpr double kHimetricToLogical = 96.0 / 2540.0;
    const auto a = first.ptHimetricLocation;
    const auto b = second.ptHimetricLocation;
    using flutter::EncodableValue;
    channel_.InvokeMethod(
        "contacts", std::make_unique<EncodableValue>(flutter::EncodableList{
                        EncodableValue(cursor.x / pixel_ratio),
                        EncodableValue(cursor.y / pixel_ratio),
                        EncodableValue((a.x + b.x) * 0.5 * kHimetricToLogical),
                        EncodableValue((a.y + b.y) * 0.5 * kHimetricToLogical),
                        EncodableValue((b.x - a.x) * kHimetricToLogical),
                        EncodableValue((b.y - a.y) * kHimetricToLogical),
                    }));
  }

  void EndGesture() {
    if (!last_frame_) return;
    last_frame_.reset();
    channel_.InvokeMethod("contacts", nullptr);
  }

  const ReadTouchpadFrame read_frame_ = reinterpret_cast<ReadTouchpadFrame>(
      TouchpadFunction("GetPointerFrameTouchpadInfo", 2693));
  flutter::MethodChannel<flutter::EncodableValue> channel_;
  HWND window_ = nullptr;
  std::optional<UINT32> last_frame_;
};

class TalDragPreviewPlugin : public flutter::Plugin {
 public:
  explicit TalDragPreviewPlugin(flutter::PluginRegistrarWindows* registrar)
      : registrar_(registrar), trackpad_(registrar) {
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
  PlotTrackpad trackpad_;
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
