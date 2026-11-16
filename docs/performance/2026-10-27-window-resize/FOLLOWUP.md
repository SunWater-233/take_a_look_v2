# Windows 窗口缩放：后续定位与当前解决方案

建议在当前 Flutter 3.47.8 上采用已实现的组合：**主窗口使用独立 Dart UI 线程，复用面板内容，外窗口缩放时立即更新布局**。保留现有独显优先、默认渲染器和自绘标题栏。

它显著减少了自动缩放中的百毫秒停顿，并降低了业务界面的构建耗时。剩余约 19 ms 的光栅化 P95 包含引擎和 Windows 呈现同步，仍不能宣称稳定达到 60/144 FPS。

## 发现与处理

### 1. 主窗口的线程策略会放大缩放停顿

原主窗口未设置 `UIThreadPolicy`。本机 SDK 的 `flutter_windows_engine.cc:371` 实际将 `Default` 与 `RunOnPlatformThread` 都映射到 Windows 平台线程；不能只依据头文件中仍描述旧默认值的注释判断。

同一 SDK 的 `FlutterWindowsView::OnWindowSizeChanged` 会在平台线程等待新帧，超时阈值 100 ms，并在等待中轮询平台任务。让 Dart 帧生产也运行在该线程，会把窗口消息处理与帧调度耦合。完整界面三轮合并线程对照共 1746 次尺寸请求，其中 90 次达到或超过 100 ms；独立 UI 线程、尚未复用面板的三轮对应结果为 1/1746。

`windows/runner/main.cpp` 现显式设置：

```cpp
project.set_ui_thread_policy(flutter::UIThreadPolicy::RunOnSeparateThread);
```

这与 `desktop_multi_window` 现有子窗口配置保持一致，使用公开 Embedder API，无需修改 SDK 或引擎二进制。Flutter 官方曾针对 Windows 线程合并性能回退提供过相同方向的临时措施；这不代表该历史问题就是本机全部耗时的原因。[官方问题 #178916](https://github.com/flutter/flutter/issues/178916)、[当前引擎线程映射说明](https://api.flutter.dev/windows-embedder/classflutter_1_1_flutter_windows_engine.html)。

### 2. 窗口几何变化不应重建所有面板控件

`DockingWorkspace` 原先在每次尺寸改变时重新创建已保留面板的 body widget，导致不依赖尺寸的控件也进入构建流程。

现按面板保存 body；控制器或可见性变化时替换，控制器替换时清空缓存。原有模型监听和主题继承仍有效，嵌套 `LayoutBuilder` 与 render constraints 仍及时响应尺寸变化；不会冻结面板画面或延迟内容更新。缓存每个面板最多一个 body，数量受有限面板类型约束。

在同一独立 UI 线程策略下，采用“复用第 1 轮 → 不复用对照 → 复用第 2 轮”的顺序复核，UI 构建 P95 为 **6.992 → 8.634 → 6.806 ms**，降低约 19%～21%。

### 3. 原生合成同步是已测出的剩余成本

新增可选原生诊断构建，计时主窗口 `WM_SIZE` 处理，以及 Flutter DLL 对真实 `DwmFlush` 的调用。计时包装始终调用原 API，没有跳过同步，也没有改动引擎文件。跟踪通过进程内导入表接入，仅编译到显式开启诊断的构建中。

最终两轮每轮都有 576 次实际尺寸变化及 576 次对应 `DwmFlush`，后者 P95 为 **9.679 / 9.875 ms**。这说明光栅化墙钟时间包含呈现等待，不能直接解释为显卡纯绘制时间。各阶段 P95 也不能相加后作为鼠标延迟。

本机 `flutter_windows_view.cc:822` 的缩放路径还会销毁、重建 EGL 表面。这一操作尚未被单独计时，因此不能将扣除合成等待后的全部耗时都归因于表面重建。Flutter 上游仍跟踪这一优化方向，过去直接改用自动表面尺寸也出现过显示回退。[上游跟踪 #79427](https://github.com/flutter/flutter/issues/79427)、[相关回退 #76465](https://github.com/flutter/flutter/issues/76465)。

## 对照数据

延续第一阶段的机器、144 Hz 显示器、125% DPI、Release AOT、独立布局和 582 次三方向尺寸请求。所有有效性能运行顺序执行，构建和测试不与测量并行。后台负载和系统调度仍会产生轮间波动。

下表是当前这一阶段的数据，均已包含第一阶段的动画滞后修复。调用 P95 指 `windowManager.setSize` 往返耗时；它不是实测鼠标端到端延迟。

| 配置 / 原始运行目录 | UI 构建 P95 | 光栅化 P95 | 尺寸调用 P95 | ≥100 ms 调用 |
| --- | ---: | ---: | ---: | ---: |
| 合并线程第 1 轮 `merged-1` | 7.197 ms | 19.682 ms | 124.235 ms | 32/582 |
| 独立线程第 1 轮 `separate-1` | 8.715 ms | 19.221 ms | 39.116 ms | 0/582 |
| 合并线程第 2 轮 `merged-trace-2` | 7.261 ms | 19.291 ms | 41.985 ms | 22/582 |
| 独立线程第 2 轮 `separate-trace-2` | 8.668 ms | 19.335 ms | 39.911 ms | 1/582 |
| 独立线程第 3 轮 `separate-dwm-3` | 13.715 ms | 22.778 ms | 46.171 ms | 0/582 |
| 合并线程第 3 轮 `merged-dwm-3` | 9.788 ms | 19.894 ms | 150.467 ms | 36/582 |
| 最终方案第 1 轮 `cached-1` | **6.992 ms** | **19.039 ms** | **38.189 ms** | **0/582** |
| 独立线程、不复用面板 `uncached-confirm` | 8.634 ms | 19.019 ms | 41.308 ms | 1/582 |
| 最终方案第 2 轮 `cached-2` | **6.806 ms** | **18.992 ms** | **37.203 ms** | **0/582** |

最终两轮主窗口 `WM_SIZE` 处理 P95 为 **29.131 / 28.126 ms**，面板目标与实际几何位置误差均为 **0**。这些结果支持减少停顿和重复构建，不支持声称所有帧耗时都有同等改善。

完整汇总见 [followup-results.json](followup-results.json)，源码与保留诊断包的哈希见 [followup-environment.json](followup-environment.json)。原始逐帧数据、CSV 和日志在 `build/window_resize_20261027_followup/`。汇总按同目录 `native-trace.csv` 读取原生计时；阶段分组覆盖完整尺寸调用区间，包含没有帧运行的阻塞时段，不只统计与帧重叠的操作。

实际运行顺序为：合并 1、独立 1、空白合并、空白独立、合并 2、独立 2、空白独立跟踪、独立 3、系统标题栏、合并 3、最终 1、不复用复核、最终 2、原生键盘缩放检查。

## 已比较但未采用的方向

- **只优化业务界面无法消除全部缩放成本。** 空白场景 UI 构建 P95 仅 0.370～0.390 ms，光栅化仍为 19.554～21.741 ms。空白场景没有后端及预热子引擎，只用来确认基础窗口链路本身有成本，不把它与完整界面的差值解释为纯控件成本。
- **系统标题栏收益不足。** 与相邻独立线程运行相比，单轮系统标题栏的光栅化 P95 为 21.746 ms，对照为 22.778 ms；尺寸调用 P95 为 45.043 vs 46.171 ms。正常标题栏还改变了客户区面积。这不足以支持为性能更改窗口外观。
- **切核显或 Skia。** 第一阶段对照未得到明确改善，正式配置仍使用独显优先与默认渲染器。
- **跳过 DwmFlush、延迟缩放、停绘后拉伸截图、修改 Flutter 引擎。** 没有作为修复实施。当前收益来自正常帧调度和减少无关构建，不以画面失真换取低耗时。

## 验证及边界

- 76 项相关测试通过：尺寸跟随、面板状态、隐藏可见性、标签和停靠、独立窗口、UI 缩放、鼠标和触控布局、输出面板。
- `flutter analyze --no-pub` 无问题，正常 `lib/main.dart` 的 Windows Release 构建成功。
- 原生键盘缩放检查通过：进入 Windows `SC_SIZE` 模态流程，执行右、下、右、左、上方向键并确认结束；记录 6 次有效尺寸变化和 `resized` 结束事件，布局误差为 0。它是原生消息和布局的功能检查，样本量不足以作为连续鼠标拖边性能结论。
- 三轮合并线程对照的子引擎启动日志均出现一次 `NO_HANDLER` 初始快照异常；独立线程及最终两轮没有。主引擎测量结果的 `errors` 均为空，三引擎均记录 RTX 4060。该启动差异也应计入线程策略比较的边界，不能把所有差异概括成 GPU 性能变化。
- 前两次原生诊断构建未接入延迟导入的 DwmFlush，仅 `WM_SIZE` 计时有效；汇总的 `dwmTraceInstrumented` 为 false，不将缺少数据视作零等待。后续成功接入的运行才用于合成等待结论。
- 原用户 `watch_browser.dart` 改动保持不变。没有修改 SDK、驱动、Windows 图形设置或采样行为。

独立 UI 线程是当前版本的兼容措施，引擎会提示未来可能移除此模式。升级 Flutter 时需重新跑这组基准，检查该 API 与窗口插件兼容性；待上游解决线程合并和表面缩放问题后再评估恢复默认策略。当前无需仅为拖边问题重写整个界面框架。

## 复现后续诊断

在仓库根目录执行，`cmake` 应使用 Flutter 配置时采用的 Visual Studio CMake：

```powershell
cmake -S windows -B build/windows/x64 -DTAL_WINDOW_RESIZE_DIAGNOSTICS=ON
flutter build windows --release --target tool/benchmarks/window_resize_benchmark.dart
$env:TAL_RESIZE_BENCH_DIR = Join-Path (Get-Location) 'build/resize-check/followup'
New-Item -ItemType Directory -Force $env:TAL_RESIZE_BENCH_DIR | Out-Null
# 1：正常独立 UI 线程；0：仅诊断构建可用的合并线程对照。
$env:TAL_RESIZE_BENCH_SEPARATE_UI = '1'
$app = Join-Path (Get-Location) 'build/windows/x64/runner/Release/take_a_look_v2.exe'
$process = Start-Process $app -WorkingDirectory (Split-Path $app) -WindowStyle Hidden -PassThru
$process.WaitForExit()
.\backend\.venv\Scripts\python.exe tool/benchmarks/summarize_window_resize.py "$env:TAL_RESIZE_BENCH_DIR/results.json"
Remove-Item Env:TAL_RESIZE_BENCH_DIR,Env:TAL_RESIZE_BENCH_SEPARATE_UI
# 恢复正常入口及关闭原生诊断。
cmake -S windows -B build/windows/x64 -DTAL_WINDOW_RESIZE_DIAGNOSTICS=OFF
flutter build windows --release --target lib/main.dart
```

`TAL_RESIZE_BENCH_SCENE=empty` 选择空白场景；`TAL_RESIZE_BENCH_TITLEBAR=normal` 比较系统标题栏。`TAL_RESIZE_BENCH_MODE=native-keyboard` 在诊断构建中进入 Windows 键盘缩放模式，方向键缩放、Enter 确认后，向输出目录写入 `native.done` 结束记录。普通构建默认不包含原生跟踪、导入表包装或线程策略对照开关。
