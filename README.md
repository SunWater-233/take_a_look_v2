# Take A Look V2

Flutter desktop rewrite of the Take A Look embedded real-time tuning
workstation. The UI runs in Flutter; hardware access runs in a local Python
process. This process can use a local USB probe or act as a client of an
EmberMobile gateway / remote GDB Server; it does not expose a network listener.

## Implemented backend capabilities

- ELF/AXF symbol and DWARF type parsing, including arrays, structures and pointer metadata
- pyOCD probe discovery, target connection, coalesced memory reads, typed writes and readback verification
- Configurable memory sampling from 1 Hz to 10 kHz
- J-Scope-compatible RTT-Normal and configured-variable RTT-Plus sampling
- Target reset/run and reset/halt control
- EmberMobile v2 QUIC binary push (with v1 compatibility), remote RTT-Normal/RTT-Plus, and GDB/MI remote debugging
- DWARF source browsing with C/C++ syntax highlighting, source-line breakpoints,
  halt/resume/instruction-step controls, current-PC highlighting, and registers
- In-memory raw sample cache, pause/resume, clear and UTF-8 CSV export
- Versioned JSON-lines RPC with state, sample, log and performance events
- One hardware backend owned by the main window; detached Flutter windows use the existing main-window channel

## Development

Prerequisites are Flutter, Python 3.11 or newer, and platform build tools.

```powershell
.\tool\setup_backend.ps1
flutter pub get
flutter run -d windows
```

The app searches for Python in this order:

1. `TAKE_A_LOOK_PYTHON`
2. a packaged runtime under `backend/runtime/`
3. `backend/.venv`
4. the `python` command on `PATH`

`TAKE_A_LOOK_BACKEND_DIR` can override the backend source directory. These
overrides are useful for development and diagnostics; normal development uses
`backend/.venv` automatically.

## Source layout

Flutter implementation files are grouped by responsibility under `lib/src/`:

| Directory | Responsibility |
| --- | --- |
| `app/` | App bootstrap, main/detached window composition, title bar, and file pickers |
| `controller/` | Application state, command routing, notifications, and controller extensions |
| `backend/` | Local Python process client, RPC transport, and sample decoding |
| `protocol/` | Shared command and event definitions |
| `models/` | Domain models and demo data |
| `telemetry/` | Sample buffers and telemetry storage |
| `analysis/` | Analysis data, statistics, FFT, and background workers |
| `chart/` | Realtime chart interaction, rendering, axes, viewport, and downsampling |
| `panels/` | Workspace panel bodies, tables, source search, and panel-specific widgets |
| `workspace/` | Docking layout, panel types, keyboard shortcuts, window sync, and drag coordination |
| `theme/` | Shared visual styles, adaptive input policy, and common UI controls |

`lib/main.dart` starts `app/app.dart`. The controller and panel libraries keep
their existing `part` organization inside their directories; import
`controller/controller.dart` or `panels/panels.dart` instead of importing a
`part` file directly. Benchmark scripts use the current source paths; archived
performance results retain the paths recorded when those measurements ran.

## Shared UI and input modes

The shared UI module lives in `lib/src/theme/`. Pages import its public entry
point, `theme/theme.dart`; module internals import their specific dependencies
directly instead of importing the public entry point.

- `tokens.dart`: colors, fonts, text styles, and shared border tokens.
- `material_theme.dart`: `buildTalTheme` and Material component styles.
- `interaction.dart`: `TalUiTheme` dimensions and `TalInteractionRegion` input policy.
- `controls.dart` / `dropdown.dart`: `TalButton`, `TalIconButton`,
  `TalPopupMenuButton`, and `TalDropdown`.
- `menus.dart`: context menus, selection menus, and menu animation.
- `feedback.dart`: `showTalDialog`, `TalDialog`, and `TalFeedbackController`.

New panels should use these shared controls and theme values instead of adding
their own device checks or fixed control sizes.

`TalInteractionRegion` follows actual mouse/keyboard, touch, and pen input in
each window. Desktop controls are compact (32 logical pixels); touch controls
use 48-pixel targets. Size changes wait until the active gesture ends. Desktop
errors appear at the bottom right without blocking the workspace, retain
expandable/copyable details, and stay until closed or replaced by a newer error.
Touch errors keep the centered confirmation dialog. Full error history remains
in the event log. This input policy is independent of UI zoom and window width.

## GPU selection

Windows, Linux and macOS desktop windows prefer a high-performance GPU when one
is available. The policy also applies to detached and prewarmed windows. GPU
selection affects rendering; sampling and FFT still run on the CPU.

- Windows tries Flutter's high-performance preference, then the low-power
  preference, then system defaults if engine initialization fails.
- Linux uses `switcheroo-control` to discover discrete GPUs and their driver
  settings. A separate, hidden OpenGL probe validates each candidate, with a
  five-second timeout. Missing discovery support or failed probes leave the
  system-default path available. Working explicit PRIME settings are respected.
- macOS prefers a usable non-low-power Metal device before creating Flutter
  surfaces. The current Flutter engine needs a guarded compatibility adapter;
  an incompatible engine or failed Metal resource creation keeps its original
  renderer. Apple silicon and other single-GPU systems keep their available GPU.

Set `TAKE_A_LOOK_GPU=system` before launch to bypass the application's GPU
preference. This is a diagnostic escape hatch and does not change OS settings.
GPU changes take effect after restarting the application. See
[GPU selection and verification](docs/gpu-selection.md) for implementation
constraints and native validation commands.

## Source debugging

The connection panel supports **本地 USB / pyOCD**, **EmberMobile 私有协议**,
**EmberMobile + GDB**, and **远程 GDB**. For the phone workflow, authorize the
USB probe, attach the target, and start the gateway in EmberMobile first. Enter
the phone address, gateway port (4242), and the current access token in Take A
Look. The symbol file remains on the computer.

**EmberMobile 私有协议** supports live memory reads, run control, registers,
address breakpoints, and both RTT sampling formats. The v1 gateway does not
provide arbitrary memory writes, so variable write controls are disabled.

**EmberMobile + GDB** uses the private gateway for RTT and an installed GDB for
debug control and memory writes. Enter the GDB port (3333) and the path to an
appropriate GDB, such as `arm-none-eabi-gdb.exe` for Cortex-M. An empty path
uses `TAKE_A_LOOK_GDB`, then `arm-none-eabi-gdb`, `gdb-multiarch`, or `gdb` on
PATH. The application starts the phone GDB listener if needed; an existing
listener must match the port/core and have no connected client. GDB attaches
with the target halted. Resume it to capture RTT; halt it to inspect or write
variables. Full-stop GDB is not used for running-target memory polling.

**远程 GDB** connects to an already running RSP server without requiring an
EmberMobile token. The current register panel targets ARM/Cortex-M. This mode
does not supply RTT. GDB is an external executable and is not included in the
application bundle; `pygdbmi` is included in the Python backend dependencies.

On disconnect, the application detaches GDB and closes only the phone GDB/RTT
services it started. It preserves an adopted phone listener or RTT capture.
Network errors do not automatically replay target mutations. RTT overflow,
session changes, and target epochs stop decoding rather than joining unrelated
sample bytes; restart RTT sampling after restoring the target. A shared capture
whose retained history has already overflowed must be restarted on the phone.
RTT channels still need the existing `JScope_<FORMAT>` or RTT-Plus firmware
format; arbitrary text logs are not interpreted as waveform samples.

New phone tokens contain a secret and certificate fingerprint. The adapter
retrieves only the public certificate over TCP 4242, checks its fingerprint,
and connects with verified TLS to QUIC/UDP 4243. It does not send the secret
over the bootstrap TCP connection. Older tokens continue to use v1; a failed
v2 handshake never silently downgrades. The connection panel displays the
negotiated version. Install `aioquic` through the backend setup script; it is
included in packaged builds.

TCP-only ADB forwarding cannot carry QUIC. Use the phone's LAN address for v2,
or explicitly launch with `EMBER_PROTOCOL=1` for the v1 TCP compatibility path.
This is an explicit legacy choice, not an automatic fallback after TLS failure.

RTT v2 data is pushed as raw binary on a separate authenticated data connection,
so its congestion window and buffers do not block control RPCs. Reliable
delivery is the default. **实时优先（Normal）** sends whole sample frames as
QUIC Datagrams, discards outdated data, and reports skipped bytes in
`perf.rttDroppedBytes`. RTT-Plus stays reliable because configuration responses
and data share its channel. Timestamped firmware samples are recommended;
untimestamped samples still use a nominal, approximate time axis. The reliable
client cache is limited to 1 MiB and reports overflow; realtime preview uses
64 KiB and an approximately 20 ms local queue budget. Reset/epoch changes stop
the old stream. v2 memory blocks can carry 64 KiB without JSON byte arrays.

Sampling rate remains limited by the probe, phone capture loop, and network;
the UI's requested frequency does not guarantee physical throughput. See
EmberMobile's `docs/protocol-v2.md` for the wire contract and benchmark scope.

Load an ELF/AXF file built with DWARF debug information (`-Og -g3` is
recommended for GCC/Clang), then open the **源码调试** tab beside the realtime
plot. Executable line numbers are highlighted in gray; click one to add or
remove a breakpoint. Lines without generated instructions cannot accept a
breakpoint.
Verified breakpoints are red; pending or rejected breakpoints are amber and
show their status in a tooltip. When the target halts, the panel opens the
current source file, highlights the program-counter line, and displays core
registers along the bottom. Source files open in closable tabs; overflowing
tabs scroll horizontally and fade at the right edge to reveal that more files
are available. Press `Ctrl+W` to close the active source tab, drag external
text/source files into the panel to open them, or press `Ctrl+F` to search file
names, paths, and the contents of known and open source files. Filename search
also includes files under the configured project source root and supports fuzzy
abbreviations (for example, `mtrctrl` finds `motor_controller.c`, and `src mtr`
matches its source path). `.c` and `.h` files have the highest priority; build
outputs such as `.o`, `.obj`, and `.elf` appear last. Filename results appear
first while content results load. File paths and prepared text are cached across
queries, and binary build outputs are only matched by name. Content search uses
literal text. Use `Up`/`Down` to select a result and `Enter` to open it and close
search; `Esc` closes search without opening the selection.
Use the folder button in the source toolbar to set the project source root;
build-machine paths recorded in the ELF are then
matched to local files automatically. **定位本地源码** remains available as a
per-file fallback.

## Keyboard shortcuts

Panel commands follow the active panel. When the source debugger is visible,
`Ctrl+F` and `Ctrl+W` work throughout the window, including after using the symbol
list or a file picker; clicking a source file tab first is unnecessary. Window
commands also work when no panel control has keyboard focus. On macOS, Command
can be used in place of Ctrl.

| Shortcut | Action | Scope |
| --- | --- | --- |
| `Ctrl+0` | Reset UI scale | Main and detached windows |
| `Ctrl+Shift+S` | Save workspace layout | Main window |
| `Ctrl+F` | Open file/content search | Window with a visible source debugger |
| `Ctrl+W` | Close the active source file tab | Window with a visible source debugger |
| `Up` / `Down` | Select a search result | Source search |
| `Enter` / `Esc` | Open the selection and close search / cancel search | Source search |
| `Ctrl+A` | Select all watched variables | Active watch panel |

Focused text inputs retain their editing shortcuts, and modal dialogs take
priority over commands in the workspace behind them.

## Test

Realtime samples are stored in bounded numeric ring buffers (1,800 points per
watch); writing new samples does not shift the retained history. Sampling updates
values immediately, while display notifications and detached-window telemetry
notifications are coalesced at the selected display refresh rate. Paused plots
keep their own frozen snapshot.

FFT calculation runs in a resident analysis isolate, independently of acquisition.
Immutable signal/time datasets are uploaded once as numeric buffers; subsequent
selection and window changes reuse them. At most one job runs and one latest job
waits, and superseded results are discarded. Full frequency bins are returned as
transferable numeric data, so zooming and spectrum selection retain their detail.
Closing the analysis panel disposes its worker. The numeric analysis modules do
not depend on a specific probe backend.

```powershell
.\backend\.venv\Scripts\python -m pytest -q backend
flutter analyze
flutter test
```

Optional real-GDB protocol integration tests (the target is a local simulated
Cortex-M RSP server, not physical hardware):

```powershell
$env:TAKE_A_LOOK_TEST_GDB = 'C:\toolchain\bin\arm-none-eabi-gdb.exe'
.\backend\.venv\Scripts\python -m pytest -q backend/tests/test_gdb_remote.py
```

The Python suite is hardware-independent. It uses fake targets and channels to
test protocol handling, connection orchestration, memory codecs, coalesced
reads, RTT framing, sampling, writes, reset and CSV export.

The repeatable Windows release benchmark uses a separate, hidden application in
`build/data_benchmark/` and does not overwrite the desktop application's release
executable:

```powershell
.\tool\run_data_benchmarks.ps1 -Runs 2 -ResultSet refactor
.\tool\run_data_benchmarks.ps1 -Runs 2 -Suite worker -ResultSet refactor -SkipBuild
.\tool\run_data_benchmarks.ps1 -Runs 2 -Suite live -ResultSet refactor -SkipBuild
```

`all` measures the data algorithms, `worker` measures the production FFT worker,
and `live` exercises the real plot/watch/analysis widgets with synthetic 32-channel
10 kHz samples and changing FFT selections. The live suite records Flutter engine
frame timings in a hidden window; it does not measure physical screen presentation
or real debug-probe throughput.

The recorded baseline and refactor comparison are in
[the performance report](docs/performance/2026-09-27/refactor/REPORT.md).

## Package

Create a standalone backend before the Flutter release build:

```powershell
.\tool\build_backend.ps1
flutter build windows --release
```

The equivalent Linux scripts are `tool/setup_backend.sh` and
`tool/build_backend.sh`. The generated PyInstaller directory is placed under
`backend/runtime/take_a_look_backend/`. Windows and Linux native install rules
copy it beside the application together with the backend sources. macOS builds
must run the same backend packaging step on macOS and add the resulting runtime
to the signed app bundle so the executable matches the target architecture.

J-Link native RTT still requires the SEGGER J-Link runtime installed according
to SEGGER's license. Other probes use pyOCD's RTT memory transport. Linux users
must also install suitable udev rules for their debug probe.
