#include "gpu_preference.h"

#include <gtk/gtk.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <string>
#include <utility>
#include <vector>

namespace {

constexpr const char* kProbeArgument = "--tal-gpu-probe";
constexpr const char* kSelectionApplied = "TAKE_A_LOOK_GPU_SELECTION_APPLIED";
constexpr const char* kGpuVariables[] = {
    "DRI_PRIME", "__NV_PRIME_RENDER_OFFLOAD", "__GLX_VENDOR_LIBRARY_NAME",
    "__NV_PRIME_RENDER_OFFLOAD_PROVIDER", "__VK_LAYER_NV_optimus",
};

struct Candidate {
  int priority;
  std::vector<std::pair<std::string, std::string>> environment;
};

bool IsGpuVariable(const char* name) {
  for (const auto* variable : kGpuVariables) {
    if (g_strcmp0(name, variable) == 0) return true;
  }
  return false;
}

std::vector<Candidate> FindCandidates() {
  std::vector<Candidate> candidates;
  g_autoptr(GError) error = nullptr;
  g_autoptr(GDBusConnection) bus =
      g_bus_get_sync(G_BUS_TYPE_SYSTEM, nullptr, &error);
  if (!bus) return candidates;
  g_autoptr(GVariant) reply = g_dbus_connection_call_sync(
      bus, "net.hadess.SwitcherooControl", "/net/hadess/SwitcherooControl",
      "org.freedesktop.DBus.Properties", "Get",
      g_variant_new("(ss)", "net.hadess.SwitcherooControl", "GPUs"),
      G_VARIANT_TYPE("(v)"), G_DBUS_CALL_FLAGS_NO_AUTO_START, 500, nullptr,
      &error);
  if (!reply) return candidates;
  g_autoptr(GVariant) boxed = g_variant_get_child_value(reply, 0);
  g_autoptr(GVariant) gpus = g_variant_get_variant(boxed);
  if (!g_variant_is_of_type(gpus, G_VARIANT_TYPE("aa{sv}"))) return candidates;

  for (gsize i = 0; i < g_variant_n_children(gpus); ++i) {
    g_autoptr(GVariant) gpu = g_variant_get_child_value(gpus, i);
    gboolean is_default = TRUE;
    gboolean is_discrete = FALSE;
    g_variant_lookup(gpu, "Default", "b", &is_default);
    const bool has_discrete =
        g_variant_lookup(gpu, "Discrete", "b", &is_discrete);
    // Newer switcheroo-control identifies discrete adapters explicitly. On
    // older versions follow its own policy: prefer the non-default adapter.
    if (has_discrete ? !is_discrete : is_default) continue;
    g_autoptr(GVariant) values =
        g_variant_lookup_value(gpu, "Environment", G_VARIANT_TYPE("as"));
    if (!values) continue;
    gsize count = 0;
    g_autofree const gchar** entries = g_variant_get_strv(values, &count);
    if (count % 2 != 0) continue;
    Candidate candidate{is_discrete ? (is_default ? 1 : 0) : 2, {}};
    for (gsize entry = 0; entry < count; entry += 2) {
      if (IsGpuVariable(entries[entry])) {
        candidate.environment.emplace_back(entries[entry], entries[entry + 1]);
      }
    }
    if (!candidate.environment.empty()) candidates.push_back(std::move(candidate));
  }
  std::stable_sort(candidates.begin(), candidates.end(),
                   [](const Candidate& a, const Candidate& b) {
                     return a.priority < b.priority;
                   });
  return candidates;
}

bool ProbeEnvironment(gchar** environment) {
  g_autofree gchar* executable = g_file_read_link("/proc/self/exe", nullptr);
  if (!executable) return false;
  gchar* arguments[] = {executable, const_cast<gchar*>(kProbeArgument), nullptr};
  GPid child = 0;
  const auto flags = static_cast<GSpawnFlags>(
      G_SPAWN_DO_NOT_REAP_CHILD | G_SPAWN_STDOUT_TO_DEV_NULL |
      G_SPAWN_STDERR_TO_DEV_NULL);
  if (!g_spawn_async(nullptr, arguments, environment, flags, nullptr, nullptr,
                     &child, nullptr)) return false;
  const gint64 deadline = g_get_monotonic_time() + 5 * G_TIME_SPAN_SECOND;
  int status = 0;
  while (g_get_monotonic_time() < deadline) {
    const pid_t result = waitpid(child, &status, WNOHANG);
    if (result == child) {
      g_spawn_close_pid(child);
      return WIFEXITED(status) && WEXITSTATUS(status) == 0;
    }
    if (result == -1 && errno != EINTR) {
      g_spawn_close_pid(child);
      return false;
    }
    g_usleep(10000);
  }
  kill(child, SIGKILL);
  while (waitpid(child, &status, 0) == -1 && errno == EINTR) {}
  g_spawn_close_pid(child);
  return false;
}

}  // namespace

bool HandleGpuProbe(int argc, char** argv, int* exit_code) {
  if (argc != 2 || g_strcmp0(argv[1], kProbeArgument) != 0) return false;
  *exit_code = 1;
  if (!gtk_init_check(nullptr, nullptr)) return true;
  GtkWidget* window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
  gtk_widget_realize(window);
  g_autoptr(GError) error = nullptr;
  g_autoptr(GdkGLContext) context =
      gdk_window_create_gl_context(gtk_widget_get_window(window), &error);
  if (context) {
    gdk_gl_context_set_required_version(context, 3, 2);
    if (gdk_gl_context_realize(context, &error)) *exit_code = 0;
  }
  gtk_widget_destroy(window);
  return true;
}

void PreferHighPerformanceGpu(char** argv) {
  if (g_strcmp0(g_getenv(kSelectionApplied), "1") == 0) {
    g_unsetenv(kSelectionApplied);
    return;
  }
  if (g_strcmp0(g_getenv("TAKE_A_LOOK_GPU"), "system") == 0) return;
  // Respect an explicit desktop-launcher or user choice if it actually works.
  bool explicit_gpu = false;
  for (const auto* variable : kGpuVariables) {
    if (g_getenv(variable)) explicit_gpu = true;
  }
  if (explicit_gpu) {
    g_auto(GStrv) environment = g_get_environ();
    if (ProbeEnvironment(environment)) return;
    g_warning("Requested GPU is unavailable; using the system default GPU.");
    for (const auto* variable : kGpuVariables) g_unsetenv(variable);
    return;
  }
  const auto candidates = FindCandidates();
  for (const auto& candidate : candidates) {
    g_auto(GStrv) environment = g_get_environ();
    for (const auto& entry : candidate.environment) {
      environment = g_environ_setenv(environment, entry.first.c_str(),
                                     entry.second.c_str(), TRUE);
    }
    if (!ProbeEnvironment(environment)) continue;
    // D-Bus discovery may have started worker threads. Relaunch with the
    // validated environment instead of mutating their process environment;
    // this also applies driver settings before shared-library initialization.
    environment = g_environ_setenv(environment, kSelectionApplied, "1", TRUE);
    execve("/proc/self/exe", argv, environment);
    g_warning("Could not relaunch with the preferred GPU; using system defaults.");
    return;
  }
  if (!candidates.empty()) {
    g_warning("High-performance GPUs failed the GL probe; using the system default GPU.");
  }
}
