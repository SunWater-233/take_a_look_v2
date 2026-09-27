// Standalone native smoke tests. The same executable acts as a controllable
// graphics-driver probe child, exercising success, failure, crash and timeout.
#include "../../linux/runner/gpu_preference.h"

#include <glib.h>
#include <signal.h>
#include <sys/resource.h>
#include <unistd.h>

static void ExpectFallback(const char* behavior, char** argv) {
  g_setenv("TAL_TEST_GPU_PROBE", behavior, TRUE);
  g_setenv("DRI_PRIME", "1", TRUE);
  g_setenv("__NV_PRIME_RENDER_OFFLOAD", "1", TRUE);
  g_setenv("__GLX_VENDOR_LIBRARY_NAME", "nvidia", TRUE);
  const gint64 before = g_get_monotonic_time();
  PreferHighPerformanceGpu(argv);
  g_assert_null(g_getenv("DRI_PRIME"));
  g_assert_null(g_getenv("__NV_PRIME_RENDER_OFFLOAD"));
  g_assert_null(g_getenv("__GLX_VENDOR_LIBRARY_NAME"));
  g_assert_cmpint(g_get_monotonic_time() - before, <, 8 * G_TIME_SPAN_SECOND);
}

int main(int argc, char** argv) {
  if (argc == 2 && g_strcmp0(argv[1], "--tal-gpu-probe") == 0) {
    const char* behavior = g_getenv("TAL_TEST_GPU_PROBE");
    if (g_strcmp0(behavior, "success") == 0) return 0;
    if (g_strcmp0(behavior, "failure") == 0) return 1;
    if (g_strcmp0(behavior, "crash") == 0) {
      const rlimit no_core{0, 0};
      setrlimit(RLIMIT_CORE, &no_core);
      raise(SIGSEGV);
      return 1;
    }
    if (g_strcmp0(behavior, "timeout") == 0) sleep(20);
    int exit_code = 0;
    if (HandleGpuProbe(argc, argv, &exit_code)) return exit_code;
    return 1;
  }

  g_setenv("TAKE_A_LOOK_GPU", "system", TRUE);
  g_setenv("DRI_PRIME", "1", TRUE);
  PreferHighPerformanceGpu(argv);
  g_assert_cmpstr(g_getenv("DRI_PRIME"), ==, "1");
  g_unsetenv("TAKE_A_LOOK_GPU");

  g_setenv("TAL_TEST_GPU_PROBE", "success", TRUE);
  PreferHighPerformanceGpu(argv);
  g_assert_cmpstr(g_getenv("DRI_PRIME"), ==, "1");

  ExpectFallback("failure", argv);
  ExpectFallback("crash", argv);
  ExpectFallback("timeout", argv);

  // No discovery service must also leave the system rendering path available.
  g_setenv("DBUS_SYSTEM_BUS_ADDRESS", "unix:path=/nonexistent-tal-test-bus", TRUE);
  PreferHighPerformanceGpu(argv);
  g_assert_null(g_getenv("DRI_PRIME"));

  // The re-exec marker is consumed once and is not leaked to child backends.
  g_setenv("TAKE_A_LOOK_GPU_SELECTION_APPLIED", "1", TRUE);
  g_setenv("DRI_PRIME", "pci-0000_01_00_0", TRUE);
  PreferHighPerformanceGpu(argv);
  g_assert_null(g_getenv("TAKE_A_LOOK_GPU_SELECTION_APPLIED"));
  g_assert_cmpstr(g_getenv("DRI_PRIME"), ==, "pci-0000_01_00_0");

  int exit_code = -1;
  g_assert_false(HandleGpuProbe(argc, argv, &exit_code));
  g_assert_cmpint(exit_code, ==, -1);
  g_print("GPU preference fallback tests passed.\n");
  return 0;
}
