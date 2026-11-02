# 后端高频读写优化验证

当前生产实现与修改前源码快照使用同一基准比较。32 个连续 uint32 变量，模拟探针返回原始字节，包含真实类型解码、采样调度、原始日志和多级历史索引写盘，以及内部事件交付。约每 100 ms 并发执行一次显式写入和回读。

每个采样率运行 3 次，每次 3 秒；吞吐与 CPU 均包含结束时排空记录队列的开销。

| 设置频率 | 优化前中位数 | 优化后中位数 | 吞吐比例 | 优化后范围 |
|---|---:|---:|---:|---:|
| 50 Hz | 50.3 Hz | 50.0 Hz | 0.99 倍 | 50.0–50.3 Hz |
| 1000 Hz | 754.8 Hz | 940.0 Hz | 1.25 倍 | 928.7–972.8 Hz |
| 10000 Hz | 1168.9 Hz | 6418.8 Hz | 5.49 倍 | 4129.8–6568.2 Hz |

10 kHz 设置下，优化后 CPU 用量约 1.02–1.20 个核心。结果存在主机调度波动，不是稳定 10 kHz 或实机性能承诺。

混合 float/int32/double/uint32 类型另跑 2 次，每次 15 秒，实际频率为 5366.7 Hz、5854.0 Hz。所有基准的采集、记录和事件交付帧数均一致。

32 个连续 uint32 变量的显式写入/回读另作接口计数验证：原逐变量路径为 32 次写入和 32 次读取，新批量路径为 1 次写入和 1 次读取，回读均一致。这是目标内存 API 调用次数，不代表 USB/SWD 包数或实机加速倍数。

## 已落实的路径

- 缓存不可变变量键、采集集合及多个读取计划；预编译混合类型块解码，保留指针、别名、输入顺序和字节表示，拒绝不完整读取。
- 本地 pyOCD 对单字对齐分散地址使用 deferred reads；J-Link/ST-Link 等原生加速接口、多字块和非对齐范围保留块读取，避免将块访问拆成多次同步读取。远程适配器保留现有协议能力。
- 仅活动且高于 1 kHz 的内存采集启用短尾让出等待；等待中的显式控制请求优先于下一轮采集。
- 批量写入先验证整组输入，仅合并请求顺序中连续的待写字节，回读后才确认；前端按能力协商并合并同一微任务内的并发写入，重复写入保留顺序和独立确认。
- 记录后台合并已排队的相邻批次，保存原始时间戳；排空、导出和轮转是合并边界，不延迟等待凑批次。

## 验证边界

未连接物理探针；不包含 USB/SWD、网络、操作系统 stdio 管道或 Flutter 图表性能。分散读取批处理仅有适配器测试，没有实机吞吐证据。采样截止时间错过后会跳过，不伪造补采数据；帧数一致仅指已采集数据在记录和交付过程中一致。

远程网关没有增加分散读取协议；有线与无线收益需要根据实际往返延迟复测。批量硬件写入不是事务，异常可能发生在部分写入后，客户端不会自动重试。

## 复现

```powershell
.\backend\.venv\Scripts\python.exe tool/benchmarks/backend_throughput.py --source-root . --output build/performance_review/backend.json --runs 3 --seconds 3
.\backend\.venv\Scripts\python.exe tool/benchmarks/backend_throughput.py --source-root . --output build/performance_review/backend-mixed.json --runs 2 --seconds 15 --rates 10000 --layout mixed
```

完整原始数据、间隔 P95/P99、写入回读和暂停耗时及被测源码 SHA-256 见 [backend-high-frequency.json](backend-high-frequency.json)。

## 回归验证

- Python 后端：176 passed、3 skipped、4 subtests passed。
- Flutter：431 passed、2 skipped；`flutter analyze --no-pub` 无问题。
- 覆盖混合类型、重叠别名、读取计划失效、不完整读取、分散读取排队、批量写入预验证与顺序、前端独立确认/错误、控制优先级、记录合并/失败及导出边界。
- 本机系统临时目录曾导致跨 Python/Dart 集成检查出现权限失败和超时；将本次测试进程的 TEMP/TMP 指向项目内 `build/test_tmp` 后，相关检查和完整前端测试均通过，未修改系统环境或这些检查的断言。
- Windows Release 构建成功；打包后端及 Release 内的后端 `--self-test` 均为 `ok: true`。发布目录中的 28 个后端源码文件与工作区逐文件一致，新打包后端与发布副本 SHA-256 一致。
