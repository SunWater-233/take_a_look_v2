# Repeat 采样修复与实机验证（2026-10-23）

已修复时间、统计和包长语义，并更新手机 APK、Windows Release 前端与打包后端。
吞吐达到 2k 次/秒；本方案仍是非均匀突发读取，没有测得每个子读的时刻。

## 实现

- 每个真实子读保留数据和顺序，同批使用共同的手机提交时间，不再均摊 USB/排队耗时。
  `timing` 保存 transaction_window、batchSequence、index、repeat、start/end（秒）。
  数据贯通 JSON 采样事件、stdio v3、Dart 解码、原始记录与 CSV；普通采样沿用 v1/v2。
- 自适应按批数乘 repeat 统计样本吞吐；丢批、丢样分别记录。正确达到目标的定时流不
  再因为少算 repeat 而切换。实机定时器约只能送达 1.4k 次/秒，因此突发模式稳定窗口
  低于目标 90% 时单向切全速；普通模式保留原来的 2/3 门槛。
- DAP 请求为 `3 + 6N`，另留 SELECT/CSW 两次写的 10 字节；响应为 `3 + 4N`。
  64 字节包预算取 8 字并通过 memory_sampling_max_words 宣告。初始化/配置仍可能
  额外往返，不把一次 probe-rs 调用直接等同为一次 USB 往返。
- 已知对齐 RAM 才使用 repeat；首批前的范围校验失败回到普通采样。硬件、会话和
  代次错误不重试。每轮重复在 plan 后展开，不会被去重合并为同一次读取。

## 当前实机

OPPO PEAM00 / Android 12，Horco CMSIS-DAP v2 Bulk（VID FAED / PID 4873），
STM32H723VG，attach 指定 SWD 4000 kHz。覆盖安装保留配对，重新授权探针、连接目标后验证。
全程未提交 MCU 固件下载、内存写入、halt 或 reset 命令；结束时 attached、running，GDB 关闭。
手机 EmberMobile 进程 PID 7635 的 crash 缓冲没有记录。

直接订阅，每种场景约 4 秒，地址 0x24000000，三变量间距 64 字节：

| 场景 | 收到批次/秒 | 每变量实际读取次数/秒 |
| --- | ---: | ---: |
| 单变量 repeat=1 全速 | 2010 | 2010 |
| 单变量 repeat=2 全速 | 1351 | 2702 |
| 单变量 repeat=4 全速 | 1222 | 4888 |
| 单变量 repeat=8 全速 | 1053 | 8423 |
| 单变量 repeat=2、定时 1 ms | 715 | 1430 |
| 三个分散变量 repeat=2 全速 | 1115 | 2231 |

9 字请求被 invalid_params 拒绝；随后普通读取正常，资源名额已释放。
以上是顺序测试，受手机/USB 调度影响，不作为严格的同条件 A/B 增益。
原始数据：[直接订阅结果](ember-repeat-validation-2026-10-23.json)。

## Windows 打包版完整路径

使用 Release 目录里的真实 take_a_look_backend.exe，经 stdio、采样服务、记录工作线程
和二进制发布链路；目标设为 2000，预热 5 秒，再统计约 10 秒。加载现有 H7_Robot.axf
解析 RAM 地址，不进行下载；验证范围是读取传输和时间元数据，不据此验证变量的物理含义。

| 变量 | 地址 | 收到帧数 | 完整窗口吞吐 |
| --- | --- | ---: | ---: |
| 单 float | 0x24005f3c | 29394 | 2929.5 次/秒 |
| 三个分散 float | 0x24005f3c / 0x2400607c / 0x24005f7c | 24252 | 2416.4 次/秒/变量 |

两种情况均自动进入 full、repeat=2，timeQuality=transaction_window。逐帧验证 stdio v3
的批内顺序和事务范围；记录中分别有 40498、27214 帧带 timing（另各有 1 帧启动阶段
的普通采样），CSV 导出全部保留。对应原始记录 SHA-256、CSV 路径和行数见
[记录校验结果](ember-repeat-recording-validation-2026-10-23.json)。

这些数字是实际收到的读取吞吐，不是每 500 μs 一次的均匀采样率。直接测试的部分批间
间隙达到毫秒级；子读的真实间隔未知，不应拿目标频率替代时序用于频谱或相位判断。

## 软件验证

- Python 相关测试：58 项通过（协议、真实 QUIC fixture、采样、自适应、记录/CSV、stdio、监视模式）。
- Rust：ember-v2 memory 8 项、runtime memory 7 项、DAP 包长边界 1 项通过。
- Flutter：32 项相关测试通过；flutter analyze 无问题；Windows Release 构建完成。
- Android：ARM64、x86_64 release 原生库完成，APK 构建和 adb 覆盖安装 Success，冷启动正常。
- Windows 打包后端自检通过；发布目录与打包目录的后端 exe SHA-256 一致。

复现直接订阅：

```powershell
.\backend\.venv\Scripts\python.exe tool/diagnostics/ember_repeat_validate.py --seconds 4 --output result.json
```

完整打包路径：

```powershell
.\backend\.venv\Scripts\python.exe tool/diagnostics/ember_stdio_rate.py --exe build/windows/x64/runner/Release/backend/runtime/take_a_look_backend/take_a_look_backend.exe --elf D:/ProjectGarage/wheel_leg_rl/chassis/MDK-ARM/H7_Robot/H7_Robot.axf --rates 2000 --seconds 10 --warmup 5 --variables 3 --min-gap 64
```
