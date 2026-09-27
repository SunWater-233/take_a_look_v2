#ifndef RUNNER_GPU_PREFERENCE_H_
#define RUNNER_GPU_PREFERENCE_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <dxgi.h>
#include <wrl/client.h>

#include <iostream>
#include <memory>
#include <string>

namespace tal {

// Used by both the main window and desktop_multi_window. Each retry destroys
// the failed controller before creating a new engine, including its GL context.
inline std::unique_ptr<flutter::FlutterViewController> CreateFlutterController(
    int width, int height, const flutter::DartProject& original_project) {
  const flutter::GpuPreference preferences[] = {
      flutter::GpuPreference::HighPerformancePreference,
      flutter::GpuPreference::LowPowerPreference,
      flutter::GpuPreference::NoPreference,
  };
  wchar_t override_value[16] = {};
  const DWORD override_length = GetEnvironmentVariableW(
      L"TAKE_A_LOOK_GPU", override_value, 16);
  const bool use_system_default = override_length > 0 && override_length < 16 &&
      std::wstring(override_value) == L"system";
  for (const auto preference : preferences) {
    if (use_system_default && preference != flutter::GpuPreference::NoPreference) {
      continue;
    }
    auto project = original_project;
    project.set_gpu_preference(preference);
    auto controller = std::make_unique<flutter::FlutterViewController>(
        width, height, project);
    if (controller->engine() && controller->view()) {
      Microsoft::WRL::ComPtr<IDXGIAdapter> adapter;
      if (controller->engine()->GetGraphicsAdapter(adapter.GetAddressOf()) && adapter) {
        DXGI_ADAPTER_DESC description = {};
        if (SUCCEEDED(adapter->GetDesc(&description))) {
          std::wcerr << L"Take A Look: rendering on " << description.Description
                     << std::endl;
        }
      }
      return controller;
    }
    std::cerr << "GPU initialization failed; trying the next GPU preference."
              << std::endl;
  }
  return nullptr;
}

}  // namespace tal

#endif  // RUNNER_GPU_PREFERENCE_H_
