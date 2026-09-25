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
