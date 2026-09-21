# Take A Look V2

Flutter desktop rewrite of the Take A Look embedded real-time tuning
workstation. The UI runs in Flutter; hardware access runs in a local Python
process and is never exposed over the network.

## Implemented backend capabilities

- ELF/AXF symbol and DWARF type parsing, including arrays, structures and pointer metadata
- pyOCD probe discovery, target connection, coalesced memory reads, typed writes and readback verification
- Configurable memory sampling from 1 Hz to 10 kHz
- J-Scope-compatible RTT-Normal and configured-variable RTT-Plus sampling
- Target reset/run and reset/halt control
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

## Source debugging

Load an ELF/AXF file built with DWARF debug information (`-Og -g3` is
recommended for GCC/Clang), then open the **源码调试** tab beside the realtime
plot. Click the gutter next to a line number to add or remove a breakpoint.
Verified breakpoints are red; pending or rejected breakpoints are amber and
show their status in a tooltip. When the target halts, the panel opens the
current source file, highlights the program-counter line, and displays core
registers along the bottom. If the ELF contains a build-machine source path
that does not exist locally, use **定位本地源码** to select the matching file.

## Test

```powershell
.\backend\.venv\Scripts\python -m pytest -q backend
flutter analyze
flutter test
```

The Python suite is hardware-independent. It uses fake targets and channels to
test protocol handling, connection orchestration, memory codecs, coalesced
reads, RTT framing, sampling, writes, reset and CSV export.

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
