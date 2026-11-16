#pragma once

#include <windows.h>

namespace flutter {
class DartProject;
class BinaryMessenger;
}

// Built only with -DTAL_WINDOW_RESIZE_DIAGNOSTICS=ON. No engine binary changes.
namespace tal::resize_trace {
void Start();
void Save();
void ConfigureThreadPolicy(flutter::DartProject& project);
void InstallControl(flutter::BinaryMessenger* messenger, HWND window);

class WindowMessage {
 public:
  WindowMessage(HWND window, UINT message);
  ~WindowMessage();

 private:
  double start_us_ = 0;
  int width_ = 0;
  int height_ = 0;
};
}  // namespace tal::resize_trace
