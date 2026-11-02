# Windows 空闲窗口缩放排查

**后续排查已完成，新增线程策略和面板内容复用优化。当前方案、进一步对照数据及验证见 [FOLLOWUP.md](FOLLOWUP.md)。以下保留第一阶段的测量记录。**

当前已确认并修复面板跟随窗口时的动画滞后，但缩放时的渲染耗时仍偏高。本次不能宣称已经完全消除窗口缩放卡顿，也没有证据表明问题来自采样负载或没有选中独显。

## 测量条件

- Windows Release AOT，生产主界面、后端和两个预热窗口正常启动，未连接设备、未添加变量。
- i5-12450H、RTX 4060 Laptop GPU、Intel UHD Graphics，144 Hz 显示器、125% 系统缩放。默认三引擎日志均确认选择 RTX 4060。
- 使用独立布局文件，不读取或覆盖用户布局。修复前后包含相同的已有 `watch_browser.dart` 工作区改动，该文件 SHA-256 一致。
- 在实际可见原生窗口中调用 `windowManager.setSize`，分别水平、垂直、对角往返缩放两次，共 582 次请求；每条路径 97 个尺寸，请求以 16.667 ms 的单调时钟目标间隔推进。原生调用本身可能超过该间隔，实际没有达到固定 60 次/秒。
- 前后顺序为 before-1、after-1、核显、Skia、before-2、after-2。有效性能测量顺序执行，没有与构建或测试并行。排除启动预热和停止后的帧。
- 用 Flutter `FrameTiming` 记录 UI 构建、光栅化、帧总跨度；每帧布局完成后读取面板实际位置/尺寸，与 `AnimatedPositioned` 的目标值比较。误差单位为逻辑像素。
- FrameTiming 的系统时间戳与 Scheduler 的相对时间戳通过固定偏移匹配，允许微秒舍入造成的 ±1 µs 差异；六轮时序帧全部匹配。不用回调批次到达时的阶段来分类帧。

环境、源码哈希见 [environment.json](environment.json)，完整汇总见 [results.json](results.json)。原始逐帧数据、原生调用耗时及日志保留在仓库的 `build/window_resize_20261027/` 下。

## 结果

P95 表示约 95% 的样本不超过该值。表中构建、光栅化和原生调用是不同阶段，不能相加后解释为鼠标延迟。

| 测试 | UI 构建 P95 | 光栅化 P95 | setSize 调用 P95 | 最大面板跟随误差 |
| --- | ---: | ---: | ---: | ---: |
| 修复前，独显，第 1 轮 | 11.303 ms | 21.478 ms | 111.692 ms | 20.304 px |
| 修复后，独显，第 1 轮 | 9.046 ms | 23.706 ms | 50.151 ms | 0 px |
| 修复前，独显，第 2 轮 | 7.915 ms | 26.037 ms | 122.500 ms | 21.380 px |
| 修复后，独显，第 2 轮 | 8.130 ms | 26.302 ms | 96.720 ms | 0 px |
| 修复后，系统默认 Intel 核显 | 8.835 ms | 34.825 ms | 62.800 ms | 0 px |
| 修复后，独显 + Skia | 7.695 ms | 24.268 ms | 46.809 ms | 0 px |

两轮都消除了面板几何误差，原生调用 P95 也有所降低，但改善幅度存在波动。UI 构建与光栅化的两轮结果不足以证明稳定的帧耗时下降。光栅化 P95 仍超过 60 Hz 的 16.667 ms 预算，更超过本机 144 Hz 的约 6.944 ms 预算。

## 已确认的应用问题与修复

`DockingWorkspace` 原先只在拖内部面板边界时把 `_resizing` 设为 true，拖软件外边框不会触发这个状态。工作区尺寸变化后，各面板和侧栏手柄仍用 220 ms 的 `AnimatedPositioned` 追赶目标尺寸；连续窗口缩放不断改写动画目标，停下后还会继续布局和绘制。

新增回归测试在修复前失败：窗口从 1400 px 改为 1600 px，第一帧主面板目标宽度为 1037 px，实际仍为 837 px，相差 200 px。这是一次较大尺寸跳变；它与连续小步缩放中测得的约 20–21 px 最大误差属于不同测试。

修复在 `LayoutBuilder` 检测到工作区尺寸变化的当帧，把面板和侧栏手柄的布局动画时长设为零。侧栏展开/收起等普通操作保留动画；如果缩放开始时已有动画，会立即使用新目标位置。无需监听平台特定的缩放开始/结束事件，也不引入防抖等待。

## 剩余耗时的排查结论

1. **独显已选中。** 四轮修复前后对比均通过 stderr 核实为 RTX 4060，核显对照通过 `TAKE_A_LOOK_GPU=system` 启动并核实为 Intel。单轮核显对照没有改善光栅化 P95。
2. **单纯更换渲染器没有消除瓶颈。** 临时通过 Windows Flutter 的公开 `DartProject.set_impeller_switch(Disabled)` API 对比 Skia；这一轮仍有约 24.3 ms 光栅化 P95。临时渲染器选择代码已移除，正式程序保留 Flutter 默认渲染器和原来的独显优先策略。
3. **引擎的原生表面重建是具体的后续排查方向。** 本机 Flutter SDK 的 `flutter_windows_view.cc` 中，`OnWindowSizeChanged` 发送窗口尺寸后等待新帧完成，`ResizeRenderSurface` 在尺寸变化时销毁旧 EGL 表面并创建新表面；源码也直接标注该重建操作昂贵。剩余耗时与这条路径一致，但本次没有对 Destroy、CreateWindowSurface、GPU 执行与呈现等待分别计时，不能把全部光栅化耗时归因于其中某一项。

不建议仅凭这组结果关闭独显、切换 Skia，或修改 Flutter 引擎。进一步优化应对表面重建和呈现同步做原生跟踪，避免用延迟更新窗口内容来掩盖卡顿。

## 验证与边界

- `flutter test --no-pub test/workspace_sidebar_test.dart test/workspace_resize_test.dart test/ui_scale_test.dart`：22 项通过。覆盖连续尺寸变化、宽窄布局切换、缩放中断正在运行的侧栏动画，并确认普通侧栏动画保留。
- `flutter analyze --no-pub`：无问题。
- Windows Release 诊断构建成功；最终恢复 `lib/main.dart` 正常入口构建，正式输出为 `build/windows/x64/runner/Release/take_a_look_v2.exe`。
- 鼠标自动化实验没有产生有效的 `WM_SIZING` 事件或尺寸变化，未纳入性能结果。诊断入口的 native 模式会拒绝没有原生缩放事件的运行。
- 有效结果来自真实原生窗口的自动尺寸序列，不能等同于鼠标拖边全链路、DWM 实际呈现 FPS、GPU 纯执行时间或端到端输入延迟。没有更改 Flutter SDK、显卡驱动或系统图形设置。

## 复现

```powershell
flutter build windows --release --target tool/benchmarks/window_resize_benchmark.dart
$env:TAL_RESIZE_BENCH_DIR = Join-Path (Get-Location) 'build/resize-check/run-1'
New-Item -ItemType Directory -Force -Path $env:TAL_RESIZE_BENCH_DIR | Out-Null
$app = Join-Path (Get-Location) 'build/windows/x64/runner/Release/take_a_look_v2.exe'
$process = Start-Process -FilePath $app -WorkingDirectory (Split-Path $app) -WindowStyle Hidden -PassThru
$process.WaitForExit()
.\backend\.venv\Scripts\python.exe tool/benchmarks/summarize_window_resize.py "$env:TAL_RESIZE_BENCH_DIR/results.json"
Remove-Item Env:TAL_RESIZE_BENCH_DIR
# 恢复正常程序入口。
flutter build windows --release --target lib/main.dart
```

诊断入口会显示并自动改变窗口大小、保存测量结果、正常关闭引擎。请在测量期间保持其他负载一致，暂停构建和测试。需要保留日志时可给 `Start-Process` 增加 stdout/stderr 重定向。
