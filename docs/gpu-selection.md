# Desktop GPU selection

The desktop app requests a high-performance rendering GPU on Windows, Linux
and macOS. This is a preference with fallbacks, not a requirement for a particular
vendor or a guarantee that a broken graphics driver can be recovered. CPU
acquisition, parsing, downsampling and FFT algorithms are unchanged.

## Windows

`windows/runner/gpu_preference.h` creates every Flutter controller using the
public `GpuPreference` API. It tries high performance, low power and finally no
preference, destroying a failed controller before retrying. Flutter/ANGLE also
provides its own adapter-selection fallbacks. Successful controllers report
their actual DXGI adapter to stderr, once per engine.

The `desktop_multi_window` public callback runs after its engine is created.
`windows/gpu_preference.cmake` therefore compiles an adapted copy of that
plugin's controller-creation source. Both main and secondary windows call the
same factory. The original package and Pub cache are untouched; if a dependency
update changes the expected creation code, CMake stops with an actionable error.

Reference: [Flutter GPU preferences](https://api.flutter.dev/windows-embedder/dart__project_8h.html).

## Linux

Before GTK starts, `linux/runner/gpu_preference.cc` queries the system
`net.hadess.SwitcherooControl` service. Newer service versions identify discrete
devices explicitly; older versions use the service's non-default-device policy.
On old services this is a heuristic, not a benchmark of the adapters. Only
known PRIME graphics environment variables are accepted from discovery.

Each candidate is tested by re-executing the app with `--tal-gpu-probe`. This
mode only creates a hidden GTK window and OpenGL context: it starts no Flutter
engine or hardware backend. A failure, crash or five-second timeout rejects
the candidate. The timeout child is terminated and reaped. The app re-executes
once with the validated environment before GTK starts, avoiding environment
mutation after D-Bus creates worker threads. Every Flutter engine then inherits
the same selection. A one-use marker prevents a restart loop.

When discovery is unavailable or finds no usable candidate, the app keeps its
system-default driver settings. An explicit PRIME selection is also probed;
if it fails, its GPU-selection variables are cleared before GTK initializes.
This cannot recover a device that disappears or a driver that fails later
during rendering.

The optional discovery service is supplied by the distribution's
`switcheroo-control` package. GPU numbering is never hardcoded as `DRI_PRIME=1`.
Reference: [NVIDIA hybrid GPU selection](https://docs.nvidia.com/datacenter/tesla/driver-installation-guide/optimus-laptops-and-multi-gpu-desktop-systems.html).

## macOS

Flutter's current macOS renderer selects a unified-memory Metal device internally;
it has no equivalent public GPU preference API. `NSSupportsAutomaticGraphicsSwitching`
only controls OpenGL applications, so setting it alone would not implement this
policy for Flutter's Metal renderer.

`macos/Runner/GpuPreference.mm` adapts `FlutterViewController.loadView` before
surfaces are created, including controllers inside `desktop_multi_window`.
It only adapts an engine that has not started. It verifies the expected renderer
class, object fields and Metal context initializer before touching any state.
The preferred device, command queue and Flutter Metal context are all prepared
before they replace the original set. Unavailable devices, queue/context failures
and incompatible engine layouts keep the original renderer. Successful selection
and compatibility fallback are logged to the macOS console.

This uses Flutter implementation details and must be revalidated when upgrading
Flutter. It is intentionally fail-open to the stock renderer if those details
change. It does not change GPUs while rendering, promise recovery from eGPU
unplugging, or provide a software rasterizer on a system without usable Metal.

References: [Flutter's renderer](https://api.flutter.dev/macos-embedder/interface_flutter_renderer.html),
[Apple's OpenGL switching key](https://developer.apple.com/documentation/bundleresources/information-property-list/nssupportsautomaticgraphicsswitching).

## Override and verification

All three desktop platforms accept `TAKE_A_LOOK_GPU=system` at process launch.
This bypasses the application preference without modifying graphics settings
persistently. Existing explicit driver settings still apply. No change can
switch the adapter of an already running process.

Windows:

```powershell
flutter build windows --release
$env:TAKE_A_LOOK_GPU = 'system' # Optional: exercise the original selection path.
.\build\windows\x64\runner\Release\take_a_look_v2.exe
Remove-Item Env:TAKE_A_LOOK_GPU
```

On Linux with GTK development packages, run the native fallback tests:

```sh
mkdir -p build/gpu-tests
c++ -std=c++14 -Wall -Wextra -Werror \
  $(pkg-config --cflags gtk+-3.0) \
  linux/runner/gpu_preference.cc tool/tests/linux_gpu_preference_test.cc \
  $(pkg-config --libs gtk+-3.0) -o build/gpu-tests/linux_gpu_preference_test
build/gpu-tests/linux_gpu_preference_test
```

These tests cover a working explicit selection, probe failure, a crashing driver,
a hung driver, the system override, missing discovery and ordinary arguments.
They do not require a real discrete GPU.

On a Mac, build with `flutter build macos --release`, check the console's
`Take A Look: rendering on ...` messages, then detach a panel and check the new
engine's device too. Repeat with `TAKE_A_LOOK_GPU=system` and on a single-GPU Mac.
Windows-host builds cannot validate the macOS Objective-C++ adapter.

Android, iOS and web directories remain platform scaffolding for this desktop
workstation; this change does not add mobile or browser application support.

## Validation on 2026-09-27

| Platform | Verification |
| --- | --- |
| Windows | Release build succeeded. With the preference enabled, all three engines (main window and two prewarmed windows) reported `NVIDIA GeForce RTX 4060 Laptop GPU`. With `TAKE_A_LOOK_GPU=system`, all three reported `Intel(R) UHD Graphics`. |
| Linux | The GPU selection implementation compiled in Ubuntu 24.04 with `-Wall -Wextra -Werror`; the native fallback tests passed. Physical discrete-GPU selection and the complete Linux Flutter bundle were not tested. |
| macOS | Implementation reviewed against the installed Flutter engine sources; compilation and dual-GPU runtime verification require a Mac and remain unverified. |
