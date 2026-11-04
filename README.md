# Take A Look V2

> 嵌入式实时调参工作台。界面用 Flutter，硬件访问交给本地 Python 进程：既能直连 USB 调试探针，也能作为 EmberMobile 网关或远程 GDB 服务器的客户端，不对外监听端口。

在同一个窗口里看波形、改参数、断点调试、导出数据。

## 功能

| 模块 | 能力 |
| --- | --- |
| 符号解析 | ELF/AXF 符号与 DWARF 类型，包含数组、结构体和指针 |
| 硬件访问 | pyOCD 探针发现、连接、合并内存读取、按类型写入并回读校验 |
| 实时采样 | 1 Hz – 10 kHz；RTT-Normal（兼容 J-Scope）与 RTT-Plus |
| 源码调试 | C/C++ 语法高亮、行断点、暂停/继续/单步、当前 PC、寄存器 |
| FreeRTOS | 任务、CPU 统计、栈余量、对象关系、堆与软件定时器；冻结显示与快照导出 |
| 数据记录 | 原始数据追加落盘、按时间回看、暂停/继续、流式导出 CSV |
| 多窗口 | 面板可拖出为独立窗口，与主窗口共享采集和状态 |
| 远程连接 | EmberMobile v2（QUIC）、EmberMobile + GDB、远程 GDB |
| 芯片支持 | pyOCD 内置目录 + CMSIS DFP，内置 STM32F1/F4/H7 |
| 工程与更新 | `.talproj` 工程文件；应用内检查、下载和安装更新 |

## 安装与运行

```powershell
.\tool\setup_backend.ps1   # 准备 Python 后端
flutter pub get
flutter run -d windows
```

需要 Flutter、Python 3.11 或更高版本，以及平台构建工具。后端把 pyOCD 固定在 0.46.0；依赖有变动后重跑一次 `setup_backend.ps1`。

应用按 `TAKE_A_LOOK_PYTHON` → `backend/.venv` → `backend/runtime/` → `PATH` 中 `python` 的顺序查找解释器；`TAKE_A_LOOK_BACKEND_DIR` 可以把后端源码指向别处。

## 连接方式

| 模式 | 适用场景 | 说明 |
| --- | --- | --- |
| 本地 USB / pyOCD | 有线直连 | 功能最全，可烧写固件 |
| EmberMobile | 手机当无线探针 | 手机运行 Ember 服务，配对即用；v1 网关只读，不能写变量 |
| EmberMobile + GDB | 无线 + 完整调试 | RTT 走网关，调试和内存写入走本机 GDB |
| 远程 GDB | 接已有的 RSP 服务器 | 断点调试，或只读的高速内存采样 |

手机配对：先启动服务，选 **配对 / 管理手机** → 搜索手机 → 配对，核对两端的八位验证码，并在 120 秒内在手机上完成确认。配对不需要插探针，符号文件也留在电脑上。

远程 GDB 的只读采样模式不支持写入、单步、复位、断点、固件下载和 RTT；断点调试模式使用本机安装的 GDB。

## 使用要点

- **目标芯片**：连接设置里点 **目标芯片**，按型号、厂商或芯片包搜索；**在线下载** 可拉取官方 CMSIS-Pack，首次建立索引需要几分钟。
- **读取策略**：新变量默认 **仅监视**（10 Hz 刷新），可改为 **采集**（写入历史）或 **手动读取**。
- **改参数**：双击成员的当前值就地编辑，Enter 写入并回读校验，Esc 取消。
- **看历史**：左右拖动回看整个采样会话，超出内存缓存时自动从磁盘回读；上下拖动和缩放保持“跟随最新”。绘图缓存可选 10/30/60/120 秒，默认 60 秒。
- **记录**：原始数据追加到可执行文件旁的 `recordings/`，导出 CSV 时读取完整记录；目录超过 500 MB 会提示清理。
- **工程**：`Ctrl+S` 保存 `.talproj`，`Ctrl+O` 打开；恢复工程不会连接硬件，也不会把值写进目标。当前工程格式为 v2，不读取旧版工程。
- **固件路径**：符号变量、源码调试和下载共用工程中的一个 ELF/AXF 路径。相对输入按源码根目录解析，保存为绝对路径；切换源码目录不更换固件。编译后会提示刷新或下载；文件尚未生成时不沿用其他固件的符号。
- **源码**：加载带 DWARF 的 ELF/AXF（GCC/Clang 建议 `-Og -g3`），`Ctrl+Click` 或 `F12` 跳到定义，`Alt+F12` 预览。
- **下载**：本地烧写需要连接 pyOCD 探针并指定 ELF/AXF；EmberMobile 模式下由手机完成烧写并回读校验。

## 快捷键

| 快捷键 | 作用 |
| --- | --- |
| `Ctrl+S` / `Ctrl+O` | 保存 / 打开工程 |
| `Ctrl+0` | 重置界面缩放 |
| `Ctrl+F` / `Ctrl+W` | 搜索文件 / 关闭当前源码标签 |
| `F12`、`Ctrl+Click` | 跳到定义 |
| `Alt+F12` / `Shift+F12` | 预览定义 / 查看引用 |
| `Alt+←` / `Alt+→` | 源码位置后退 / 前进 |
| `Ctrl+A` | 全选被监视的变量 |
| `Ctrl+Z` / `Ctrl+Y` | 撤销 / 重做变量删除 |

`Ctrl+F`、`Ctrl+W` 在源码调试器可见时生效；macOS 上用 Command 代替 Ctrl。

## 开发

`lib/src/` 按职责拆分：

- `app/` 启动与窗口、`controller/` 状态与命令、`backend/` 后端客户端、`protocol/` 协议定义
- `models/` 领域模型、`telemetry/` 样本缓冲、`analysis/` 统计与 FFT、`chart/` 曲线渲染
- `panels/` 面板内容、`workspace/` 停靠布局、`theme/` 样式与控件、`updates/` 自动更新、`ui_test/` 界面测试版

改动解析器或后端源码后要重跑 `tool/build_backend.ps1`，发行构建会拒绝比源码更旧的打包运行时。

## 测试

```powershell
.\backend\.venv\Scripts\python -m pytest -q backend   # 后端，不依赖硬件
flutter analyze
flutter test
```

独立的界面测试版不连探针、不启 Python，用内存模拟器跑完整工作台：

```powershell
.\tool\build_ui_test.ps1 -Run
```

性能基准：

```powershell
.\tool\run_data_benchmarks.ps1 -Runs 2 -ResultSet refactor
```

## 打包

GitHub 云端三平台打包见 [Actions 发行构建](docs/github-actions.md)：支持选择系统、Release/Debug 和版本号，
Windows、Linux、macOS Intel / Apple Silicon 分别在原生 runner 构建，产物按“版本 → 系统”分类。

```powershell
.\tool\build.ps1 -Target windows   # MSI + 便携 ZIP
.\tool\build.ps1 -Target linux     # 通过 WSL 构建
```

也可以双击 `tool/build.cmd`。版本默认取自 `pubspec.yaml`，可用 `-Version 1.2.3+4` 指定。产物在 `build/releases/<版本>/`，日志在 `build/logs/`。构建需要 Flutter、Visual Studio C++ 桌面开发工具、Git、Python 3.11+ 和 .NET SDK 8+。

## 更多文档

| 文档 | 内容 |
| --- | --- |
| [固件状态设计](docs/firmware-context.md) | 单一路径、解析与下载流程、工程格式 |
| [应用更新](docs/app-updates.md) | 更新检查、发行资产与恢复 |
| [FreeRTOS 检查](docs/freertos.md) | 面板使用、固件配置、可选辅助模块与读取范围 |
| [桌面构建](docs/build.md) | 完整构建参数 |
| [Windows 安装](docs/windows-install.md) | MSI 构建与安装 |
| [Linux 安装](docs/linux-install.md) | 依赖、USB 权限、WSL 构建 |
| [GPU 选择](docs/gpu-selection.md) | 选卡策略与验证命令 |
| [GDB 内存采样](docs/gdb-memory-performance.md) | 远程采样的性能与限制 |
| [性能报告](docs/performance/2026-09-27/refactor/REPORT.md) | 基线测量与重构对比 |
