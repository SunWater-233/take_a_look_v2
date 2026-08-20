#include "include/tal_drag_preview/tal_drag_preview_plugin.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <memory>

namespace {

class TalDragPreviewPlugin : public flutter::Plugin {
 public:
  explicit TalDragPreviewPlugin(flutter::PluginRegistrarWindows* registrar)
      : registrar_(registrar) {}

  void SetClickThrough(bool enabled) {
    const HWND view = registrar_->GetView()->GetNativeWindow();
    const HWND window = GetAncestor(view, GA_ROOT);
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

 private:
  flutter::PluginRegistrarWindows* registrar_;
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
  channel->SetMethodCallHandler(
      [plugin_ptr](const auto& call, auto result) {
        if (call.method_name() != "setClickThrough") {
          result->NotImplemented();
          return;
        }
        const auto* arguments =
            std::get_if<flutter::EncodableMap>(call.arguments());
        if (arguments == nullptr) {
          result->Error("invalid_arguments", "Expected an argument map");
          return;
        }
        const auto iterator =
            arguments->find(flutter::EncodableValue("enabled"));
        if (iterator == arguments->end() ||
            !std::holds_alternative<bool>(iterator->second)) {
          result->Error("invalid_arguments", "Expected enabled boolean");
          return;
        }
        plugin_ptr->SetClickThrough(std::get<bool>(iterator->second));
        result->Success();
      });
  registrar->AddPlugin(std::move(plugin));
  channel.release();
}
