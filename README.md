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
- Append-only raw recordings on disk, time-based plot history, pause/resume and streaming UTF-8 CSV export
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

ELF/AXF selection and refresh show a centered progress dialog through variable
parsing, source-line indexing, and the first updated UI frame. Counts come from
the parser; steps with no known total use an indeterminate bar. The dialog
keeps the input mode captured when it opens: mouse/keyboard uses a compact
440-pixel layout, while touch uses larger text, spacing, and a width capped at
560 pixels. Loading blocks duplicate reads and accidental dismissal. Completion
closes automatically; failures preserve existing symbols and use the adaptive
error feedback above. Detached windows receive ordered progress updates.

Symbol parsing has a ten-minute backend deadline checked before replacing the
current data; its RPC allows an additional minute for error delivery. Other
commands retain their 30-second timeout. Rebuild `tool/build_backend.ps1` when
changing the parser, since packaged backend executables take precedence over
the Python sources. Optional end-to-end validation:

```powershell
$env:TAL_TEST_ELF = 'C:\firmware\motor.axf'
flutter test test/backend_symbol_load_test.dart
```

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

The source debugger also provides **工程设置**, **编译**, **下载**, and
**编译并下载**, with a collapsible output panel along the bottom. Set an existing
project source directory before running a command: it is always the subprocess
working directory. Building does not require a connected board or an existing
ELF. Commands, firmware paths, shell selection, extra toolchain directories and
output encoding are saved per project and operating system in the app's local
`source-projects.json` configuration file.

Windows defaults to PowerShell (`pwsh.exe`, falling back to Windows PowerShell);
CMD is optional. macOS defaults to zsh and Linux to Bash, using an available
POSIX shell when the default is absent. An explicitly selected missing shell is
reported instead of silently changing command syntax. Commands run without an
interactive shell profile; add toolchain directories in **高级设置** when needed.
Use the chosen shell's syntax, and make multi-step build scripts return a nonzero
exit code on failure. Output defaults to UTF-8, with a system-encoding option for
older tools. **停止编译** terminates the compiler process tree. Errors in common
`file:line:column` and `file(line,column)` formats can be clicked to open source.

Downloading currently requires a connected local pyOCD probe and an ELF/AXF file
(relative paths resolve from the source root). Remote GDB/Ember connections do
not yet provide this operation. A failed or cancelled build never starts a
download. During flashing, sampling, RTT, and competing probe operations pause;
the downloaded image supplies the new symbols, relocated watches and breakpoints
before the selected reset/halt or reset/run action takes effect. Building alone
keeps the existing target symbols. Flash failures leave acquisition paused, and
flash operations cannot be forcibly cancelled from the output panel.

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

### 独立 UI 测试版（Windows）

无需连接探针或启动 Python，即可使用正式工作台检查界面和交互：

```powershell
.\tool\build_ui_test.ps1 -Run
```

默认编译 Debug 版，保留 Flutter 布局溢出等诊断；输出为
`build/ui_test/Debug/take_a_look_ui_test.exe`。分发时复制整个 `Debug` 目录。
脚本在 `build/ui_test/source/` 中构建，共用正式版的 Dart 组件、字体和
Windows 多窗口/GPU 代码，正式版的构建目录不受影响。
需要测试发布模式表现时使用 `-Configuration Release`。

顶部工具栏提供实时波形、512 个符号/32 路采样的大量变量、空白和断开状态，
以及加载进度、加载失败、连接中断和恢复场景。键鼠/触屏预览用于检查两种
控件尺寸和错误反馈；选择“自动输入模式”恢复实际输入设备检测。
预览模式只作用于主窗口，独立窗口仍自动识别自己的输入方式。

连接、采样、变量写入、RTT 开关和源码暂停/单步/断点均由内存模拟器响应。
“读取 ELF/AXF”会加载内置符号，不解析真实固件；源码示例也随测试版生成。
可以检查变量选择、右键菜单、拖拽拆窗、绘图缩放、分析/FFT 和快捷键。
CSV 导入仍可选择本地文件，导出读取当前采集记录中的全部原始帧，包含已经离开绘图缓存的数据。
菜单栏“实时变量 → 绘图缓存”支持 10 / 30 / 60 / 120 秒，默认 60 秒；缓存按时长和采样率分配，
采样率降低时保留尚未过期的高密度数据，实际输入更快时自动扩容。绘制仅扫描可见时间段，
按像素保留最小值、最大值和首尾点。主窗口和独立窗口同步完整的保留历史。

原始数据独立追加到 `samples.talraw`，不受绘图时长、暂停绘图、隐藏曲线、移除变量或像素抽稀影响。
每批数据直接写入操作系统，导出、清空或关闭时执行刷新；记录写入失败会明确报错并暂停采样。
清空采样、重新连接正式后端或切换模拟场景会开启新记录，旧记录文件仍保留；CSV 导出使用点击时的完整记录快照。
测试版和正式版均自动在软件可执行文件旁创建 `recordings/` 保存原始数据，
例如 `build/ui_test/Release/recordings/`；工作目录、布局目录或 Python 安装位置不会改变此位置。
目录不可写时会报错并暂停采样，不会回退到 C 盘或系统临时目录。
重新运行测试版打包脚本会保留已有的 `recordings/`。
每次启动时，主窗口会异步统计 `recordings/` 及其子目录的文件总大小。
超过 500 MB（500 × 1024 × 1024 字节）时，右下角滑入一次清理提示；
点击提示或“打开记录文件夹”会在文件管理器中打开该目录，供用户手动删除不需要的历史记录。
关闭提示后本次运行不再重复提醒，独立面板窗口不会重复检查。
正式前端启动后端时通过 `TAL_RECORDINGS_DIR` 传入该目录；单独运行后端时也可显式指定，
未指定则使用后端可执行文件所在目录（源码启动时为 `backend/recordings/`）。
记录文件自带变量键和名称，采用版本 1 的 UTF-8 JSON Lines：`channels` 定义列 ID，
`frames` 保存 `[时间, 列ID, 原始值, ...]`，重复时间戳与稀疏变量不会合并。
需要在应用退出后恢复 CSV 时，可在 `backend` 目录执行：

```powershell
.\.venv\Scripts\python.exe -m take_a_look_backend.services.recording "记录文件.talraw" "输出.csv"
```
模拟采样率用于产生 UI 负载，不代表硬件吞吐或真实定时精度。

布局和诊断保存在 `%APPDATA%/TakeALookUiTest/`，与正式布局分开。
点击“导出诊断”会保存主窗口 PNG 截图和 JSON（场景、样本计数、日志、
主窗口 Flutter 异常），保存路径显示在事件日志中。
也可通过 `TAL_UI_TEST_DATA_DIR` 指定测试数据目录。

```powershell
# 控件交互、模拟命令与既有回归测试
flutter test
# 编译后启动真实 Windows 引擎，检查采样、暂停、单步、加载成功/失败并留图
.\tool\build_ui_test.ps1 -SmokeTest
```

原生自检结束后自动退出，结果和截图位于 `build/ui_test/smoke/`。
该自检不替代人工拖拽、触摸设备或真实硬件验证。开发时可使用
`flutter run -d windows -t lib/main_ui_test.dart` 热重载；需要保持正式构建
产物独立时，使用上面的构建脚本。

Realtime samples are stored in time-retained numeric ring buffers; writing new
samples does not shift the retained history. Sampling updates
values immediately, while display notifications and detached-window telemetry
notifications are coalesced at the selected display refresh rate. Paused plots
keep an immutable snapshot sharing numeric pages until a later write. Exact
page/block extrema accelerate dense plots; sparse views use a sequential pass.
Hover redraws its own layer without rebuilding the curve geometry.

Detached windows exchange typed numeric batches and acknowledged state patches.
Slow windows have independent delivery pumps with one pending update; history is
sent only to windows containing plots or analysis, and is refreshed before panel
reassignment. CSV imports read, parse and prepare numeric data in the background.
Source documents, path indexes and highlighting have separate reusable services.

The backend serializes hardware access while recording and pipe output use
bounded ordered workers. Export captures an ordered journal boundary and runs
without holding the RPC input loop. Acquisition uses `perf_counter()` deadlines;
on Windows/Python 3.11, `monotonic()` can have a 15.625 ms resolution. Requested
rates remain subject to Python scheduling and physical probe/network throughput.

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
.\tool\run_data_benchmarks.ps1 -Runs 2 -Suite audit -ResultSet audit
```

`all` measures the data algorithms, `worker` measures the production FFT worker,
and `live` exercises the real plot/watch/analysis widgets with synthetic 32-channel
10 kHz samples and changing FFT selections. The live suite records Flutter engine
frame timings in a hidden window; it does not measure physical screen presentation
or real debug-probe throughput.

The `audit` suite also covers 60-second histories, frozen and continuously moving
viewports, large fragmented JSON, window serialization, and analysis imports.
Use `-SourceRoot` to compile the same fixtures against an archived checkout,
`-BuildOnly` to finish compilation before timing, and `-FirstRun` to interleave
before/after runs. `-ProcessorAffinity` optionally limits only the benchmark
process to a fixed CPU mask on hybrid CPUs; it does not change application or OS
settings. The protocol adapter selects each checkout's production wire encoding
while preserving the same samples and operations.

`tool/benchmarks/acquisition_benchmark.py` separately measures the production
32-channel scheduling/recording loop with a fake probe and verifies that acquired,
recorded and delivered frame counts agree. It does not measure USB/SWD throughput.
The current comparison, raw measurements and source fingerprints are in
[the 2026-10-11 results](docs/performance/2026-10-11/results.json).

The recorded baseline and refactor comparison are in
[the performance report](docs/performance/2026-09-27/refactor/REPORT.md).

## Package

For a standalone Linux tar.gz (Arch Linux and other glibc distributions), run
`bash tool/package_linux.sh` with a Linux Flutter SDK and Python 3.11+. The script
builds in an isolated source copy, bundles the backend runtime, runs tests, and
creates an installer, offline self-check, ABI manifest and SHA-256 checksum under
`build/releases/`. See [Linux installation and packaging](docs/linux-install.md)
for dependency installation, USB permissions, WSL builds and compatibility limits.
Run the extracted `./install.sh` to install or upgrade an existing installation.
Upgrades keep acquisition recordings and replace obsolete application libraries;
uninstalling saves recordings outside the removed application directory.

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
