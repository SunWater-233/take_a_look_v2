#include "windows_resize_trace.h"

#include <dwmapi.h>
#include <flutter/dart_project.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <cstring>
#include <fstream>
#include <mutex>
#include <string>
#include <vector>

namespace tal::resize_trace {
namespace {
struct Sample {
  const char* event;
  double start_us;
  double duration_us;
  DWORD thread;
  int width;
  int height;
};
std::mutex sample_mutex;
std::vector<Sample> samples;
std::wstring output_directory;
bool enabled = false;
LONGLONG frequency = 0;
using Flush = HRESULT(WINAPI*)();
Flush original_flush = nullptr;

double Now() {
  LARGE_INTEGER counter;
  QueryPerformanceCounter(&counter);
  return static_cast<double>(counter.QuadPart) * 1000000.0 / frequency;
}

void Record(const char* event, double start, int width = 0, int height = 0) {
  const double elapsed = Now() - start;
  std::scoped_lock lock(sample_mutex);
  if (samples.size() < 20000) {
    samples.push_back({event, start, elapsed, GetCurrentThreadId(), width, height});
  }
}

HRESULT WINAPI TimedFlush() {
  const double start = Now();
  const HRESULT result = original_flush();
  Record("DwmFlush", start);
  return result;
}

bool ReplaceImport(IMAGE_THUNK_DATA* name, IMAGE_THUNK_DATA* target, BYTE* module) {
  for (; name->u1.AddressOfData; ++name, ++target) {
    if (IMAGE_SNAP_BY_ORDINAL(name->u1.Ordinal)) continue;
    const auto imported = reinterpret_cast<IMAGE_IMPORT_BY_NAME*>(module + name->u1.AddressOfData);
    if (std::strcmp(reinterpret_cast<const char*>(imported->Name), "DwmFlush") != 0) continue;
    DWORD old_protection = 0;
    if (!VirtualProtect(&target->u1.Function, sizeof(void*), PAGE_READWRITE, &old_protection)) return false;
    original_flush = &DwmFlush;
    InterlockedExchangePointer(reinterpret_cast<void* volatile*>(&target->u1.Function),
                               reinterpret_cast<void*>(&TimedFlush));
    DWORD ignored = 0;
    VirtualProtect(&target->u1.Function, sizeof(void*), old_protection, &ignored);
    return true;
  }
  return false;
}

// Replace only this process's Flutter DLL import with a timing wrapper that
// always calls the real API. Never skip or change compositor synchronization.
bool InstrumentFlush() {
  const auto module = reinterpret_cast<BYTE*>(GetModuleHandleW(L"flutter_windows.dll"));
  if (!module) return false;
  const auto dos = reinterpret_cast<IMAGE_DOS_HEADER*>(module);
  const auto nt = reinterpret_cast<IMAGE_NT_HEADERS*>(module + dos->e_lfanew);
  const DWORD rva = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT].VirtualAddress;
  auto descriptor = rva ? reinterpret_cast<IMAGE_IMPORT_DESCRIPTOR*>(module + rva) : nullptr;
  for (; descriptor && descriptor->Name; ++descriptor) {
    if (_stricmp(reinterpret_cast<const char*>(module + descriptor->Name), "dwmapi.dll") != 0 ||
        !descriptor->OriginalFirstThunk) continue;
    auto name = reinterpret_cast<IMAGE_THUNK_DATA*>(module + descriptor->OriginalFirstThunk);
    auto target = reinterpret_cast<IMAGE_THUNK_DATA*>(module + descriptor->FirstThunk);
    if (ReplaceImport(name, target, module)) return true;
  }
  // Flutter delay-loads dwmapi.dll in current Windows engine artifacts.
  struct DelayImport {
    DWORD attributes, name, module_handle, iat, names, bound, unload, timestamp;
  };
  const auto delay_rva = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_DELAY_IMPORT].VirtualAddress;
  if (!delay_rva) return false;
  auto delay = reinterpret_cast<DelayImport*>(module + delay_rva);
  for (; delay->name; ++delay) {
    if (delay->attributes != 1 ||
        _stricmp(reinterpret_cast<const char*>(module + delay->name), "dwmapi.dll") != 0) continue;
    if (ReplaceImport(reinterpret_cast<IMAGE_THUNK_DATA*>(module + delay->names),
                      reinterpret_cast<IMAGE_THUNK_DATA*>(module + delay->iat), module)) return true;
  }
  return false;
}
}  // namespace

void Start() {
  wchar_t path[32768] = {};
  const auto length = GetEnvironmentVariableW(L"TAL_RESIZE_BENCH_DIR", path, 32768);
  if (length == 0 || length >= 32768) return;
  output_directory = path;
  LARGE_INTEGER value;
  QueryPerformanceFrequency(&value);
  frequency = value.QuadPart;
  samples.reserve(8000);
  enabled = true;
  const bool instrumented = InstrumentFlush();
  std::ofstream status(output_directory + L"/native-trace-status.txt");
  status << "DwmFlush import instrumented: " << instrumented << '\n';
}

void ConfigureThreadPolicy(flutter::DartProject& project) {
  wchar_t value[16] = {};
  if (GetEnvironmentVariableW(L"TAL_RESIZE_BENCH_SEPARATE_UI", value, 16) > 0 &&
      value[0] == L'0') {
    project.set_ui_thread_policy(flutter::UIThreadPolicy::RunOnPlatformThread);
  }
}

void InstallControl(flutter::BinaryMessenger* messenger, HWND window) {
  if (!enabled) return;
  flutter::MethodChannel<flutter::EncodableValue> channel(
      messenger, "take_a_look/resize_diagnostics",
      &flutter::StandardMethodCodec::GetInstance());
  channel.SetMethodCallHandler([window](const auto& call, auto result) {
    if (call.method_name() == "beginKeyboardResize") {
      result->Success();
      PostMessage(window, WM_SYSCOMMAND, SC_SIZE | WMSZ_BOTTOMRIGHT, 0);
    } else {
      result->NotImplemented();
    }
  });
}

void Save() {
  if (!enabled) return;
  std::scoped_lock lock(sample_mutex);
  std::ofstream output(output_directory + L"/native-trace.csv");
  output.precision(16);
  output << "event,startQpcUs,durationUs,threadId,width,height\n";
  for (const auto& sample : samples) {
    output << sample.event << ',' << sample.start_us << ',' << sample.duration_us
           << ',' << sample.thread << ',' << sample.width << ',' << sample.height << '\n';
  }
}

WindowMessage::WindowMessage(HWND window, UINT message) {
  if (!enabled || message != WM_SIZE) return;
  start_us_ = Now();
  RECT area = {};
  GetClientRect(window, &area);
  width_ = area.right;
  height_ = area.bottom;
}

WindowMessage::~WindowMessage() {
  if (start_us_ != 0) Record("WM_SIZE", start_us_, width_, height_);
}
}  // namespace tal::resize_trace
