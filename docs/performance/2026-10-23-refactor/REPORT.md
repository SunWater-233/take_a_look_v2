# 2026-10-23 结构重构与 pyOCD 升级验证

本次在现有前后端架构上调整职责边界，保留项目文件格式、采样时间戳、采集保留策略和探针操作顺序。

## 职责调整

- `WorkspaceLayoutController` 接管网格拖动、共享边界缩放、标签插入与重排、跨组移动和面板分离。工作区 Widget 调用这些状态转换，继续负责渲染、坐标转换、原生窗口与保存通知。
- `WatchRegistry` 独立拥有变量集合、编辑草稿、选中/展开状态、删除记录、撤销重做和删除后的十秒采集宽限期。主控制器负责后端命令、曲线高亮和通知。保留最多五十批撤销记录，释放记录时取消计时器并清理样本。
- `DebugSession` 独立拥有调试信息、断点、跨断点单步、寄存器和停止位置。它不引用 `BackendService`，也不创建锁或线程；所有目标操作继续使用服务原有的探针锁，与采样及固件下载保持串行。
- 面板分成源码、分析、监视、符号、连接、控制、图表/日志和框架等独立 Dart 库。`part` 仅用于功能内部。共享表格交互及源码拖拽数据通过公开接口连接，`panels.dart` 保留工作区组装入口。
- 主窗口和分离窗口使用后端发布的连接能力，新增可选 `targetControl` 字段。旧后端和离线演示使用配置默认值；能力不写入项目文件，切换连接配置时清除旧能力。
- pyOCD 固定为 `0.46.0`，同步依赖锁和已跟踪的包元数据，并升级本地虚拟环境、重新生成打包运行时。后端自检输出实际 pyOCD 版本。

## 自动验证

- `flutter analyze --no-pub`：通过，无诊断。
- `flutter test --no-pub --reporter expanded`：483 passed，2 skipped。
- `backend/.venv/Scripts/python.exe -m pytest -q backend`：235 passed，25 skipped，4 subtests passed。
- `backend/.venv/Scripts/python.exe -m pip check`：无依赖冲突。
- `uv lock --check --project backend`：通过。
- `tool/build_backend.ps1`：构建成功；生成的后端 `--self-test` 返回 `ok: true`、`pyocd_version: 0.46.0`。
- `flutter build windows --debug`：构建成功，输出 `build/windows/x64/runner/Debug/take_a_look_v2.exe`。应用目录内的后端自检也通过、pyOCD 为 0.46.0，后端 EXE 与新打包运行时的 SHA-256 一致。

新增测试覆盖后端能力覆盖配置默认值、能力在窗口增量快照中传播、旧后端兼容、独立标签转移、断点恢复顺序和独立调试状态刷新。源码面板保活测试改用公开 Widget 类型定位，保留原有状态身份及可见性断言。

## 采样性能对比

重构前版本为 Git `409418c` 的后端源码快照，双方使用同一 Python 环境及 pyOCD 0.46.0。32 个连续 uint32 变量，每个频率运行三次、每次三秒；约每 100 ms 并发进行显式写入和回读。两组依次执行，未与打包或前端测试并行。

| 设置频率 | 重构前吞吐中位数 | 重构后吞吐中位数 | 重构前范围 | 重构后范围 |
| --- | ---: | ---: | ---: | ---: |
| 1000 Hz | 989.9 Hz | 989.0 Hz | 988.8–990.3 Hz | 988.8–992.3 Hz |
| 10000 Hz | 6392.4 Hz | 6540.2 Hz | 6348.1–6748.0 Hz | 6538.6–6744.3 Hz |

各轮采集、写入原始记录、交付事件的帧数完全一致。吞吐包含结束时排空队列的耗时。10 kHz 设置下 CPU 中位数由约 1.11 个核心变为约 1.11 个核心；本次结果没有显示明显吞吐退化，不能据此认定获得稳定性能提升。

原始数据及被测源码哈希见 [before.json](before.json) 和 [after.json](after.json)。复现命令：

```powershell
.\backend\.venv\Scripts\python.exe tool/benchmarks/backend_throughput.py --source-root . --output build/refactor-performance-after.json --runs 3 --seconds 3 --rates 1000,10000
```

## 验证边界

性能基准使用返回真实字节并执行生产解码、调度、记录及事件交付的模拟目标，不包含 USB/SWD、QUIC 网络、stdio 管道或 Flutter 绘图开销。没有连接物理探针，也没有验证实机固件下载。依赖外部 ELF、芯片包、GDB 或 Ember 测试服务的部分检查按原有条件跳过。原生跨平台窗口行为仍需在相应系统实机验证。
