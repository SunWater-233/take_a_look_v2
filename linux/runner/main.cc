#include "my_application.h"
#include "gpu_preference.h"

int main(int argc, char** argv) {
  int probe_exit_code = 0;
  if (HandleGpuProbe(argc, argv, &probe_exit_code)) return probe_exit_code;
  PreferHighPerformanceGpu(argv);
  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
