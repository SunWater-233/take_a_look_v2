# EmberMobile 私有协议采样性能

## 2026-10-22 后续优化与当前实测

370 Hz 是下文记录的旧实现结果，不能作为 USB 或当前实现的上限。本轮未修改、下载或复位 MCU 固件，保留电脑端自适应定时/全速逻辑，在 EmberMobile/probe-rs 中完成：

- 复用已初始化的 MEM-AP 配置，省去短期核心句柄反复读取 IDR、CSW、CFG 的 USB 往返；宽度、配置、复位/重新初始化、原始探针借用及访问错误使缓存失效，原始寄存器读取仍访问硬件。
- 把小批次中每个变量的精确 TAR 写、DRW 读合并为有序 `DAP_Transfer`，分别校验请求和响应包长，返回所有读取结果。三个分散变量可共用一条命令；不读地址空隙，不扩读外设，不重放失败写入。
- 每条订阅保留一个阻塞采样任务，省去逐样本的异步线程到阻塞池再到探针线程的额外切换；等待可被取消唤醒，仍保留全局名额、代次检查和探针串行执行。

当前实机：OPPO PEAM00、Android 12、Horco CMSIS-DAP v2/Bulk（VID FAED/PID 4873，序列号 343420328170）、STM32H723VG、SWD 4 MHz。此探针身份与早前 370 Hz 测量时的 PID 4870/序列号 846703532121 不同，因此不把两者的速率比值当成严格的同硬件 A/B 对照。

| 验证路径 | 实测有效速率 |
| --- | --- |
| 手机全速订阅，单个 4 字节 RAM 值 | 1292 Hz |
| Windows 打包后端、真实 ELF 的单个 float、完整 stdio/记录路径 | 1305 Hz |
| Windows 打包后端、三个分散的真实 float、完整 stdio/记录路径 | 1173 Hz |
| 三个相邻 4 字节值，完整服务/记录路径 | 稳定窗口约 1126–1276 Hz |
| 三个相距 64 字节的值，完整服务/记录路径 | 稳定窗口约 1091–1382 Hz |

三变量每批总计 12 字节；典型手机单次读取约 0.6–0.7 ms。测试请求 7 kHz，实际记录按真实读取时间戳输出，绝不复制插值成目标频率。自适应模式启动和切换期间有慢窗口，其中一次约 3.3 秒；表中区间是切换到全速后的窗口，不代表全程稳定硬实时。15 秒分散三变量运行末次全速订阅计数为 251 个被 latest-only 发送端覆盖的样本，`skipped_ticks=0`；该计数在重新订阅时归零，不能直接当作所有阶段的总和。

原始日志：`ember-memory-final-sparse.log`、`ember-memory-adjacent-3.log`、`ember-memory-final-packaged.log`、`ember-memory-final-packaged-3.log`。打包版三变量地址为 `0x24005f3c`、`0x2400607c`、`0x24005f7c`，均来自真实 ELF 的电机电流 float 字段，连续 12 秒收到 14364 个采样帧。重现时将手机 SWD 设为 4000 kHz、take_a_look 采样率设为 5/7 kHz，让实际硬件吞吐决定全速结果。MCU 保持运行。

硬件数据一致性额外验证：对三个分散 Flash 地址交替使用原有字节读取与新 32 位批量读取，连续十轮结果逐字节相同；验证结束目标仍为 running，手机进程 crash 缓冲为空。

相关验证覆盖 AP 缓存失效、三地址响应顺序/截断、双向 DAP 包长、MMIO/未知区域、代次、取消、全局限制，以及 60 秒周期采样的立即取消；Android 两个 ABI 和 Windows 打包自检均通过。

下面保留此前版本的分析与历史数字；其中“USB 理论下限”的推断已被后续实测否定。`DAP_Transfer` 的多次读写顺序由 [Arm 官方协议](https://arm-software.github.io/CMSIS-DAP/latest/group__DAP__Transfer.html) 定义。

## 370 Hz 版本的历史记录

本文记录 take_a_look 通过 EmberMobile（QUIC v2）采样内存变量时实测的采样上限、
各环节耗时以及可调开关。数据来自本机 OPPO PEAM00（Android 12）+ 全速
CMSIS-DAP v2（bulk 接口）+ STM32H723VG，2026-10-22 实测。

## 结论

单个 4 字节变量在该链路上的实际上限约 **370 Hz**（USB 流水线之前约 190–200 Hz），
瓶颈在手机侧：手机每采一个样本都要对探针做一次完整读取，一次读取的成本是一次
USB 往返，与变量数量无关。

| 环节 | 实测 | 说明 |
| --- | --- | --- |
| 手机单次内存读取 `duration_us` | 1.7 ms（流水线前 4.1–4.4 ms） | `backend.memory_batch` 前后由手机计时 |
| 其中 USB 往返 | ≈ 1.7 ms | 全速 USB（64 字节 bulk 包），OUT 一帧 + IN 一帧，已无主机侧多余往返 |
| 每个 64 字节包的增量 | ≈ 4.5 ms | 4 KB 块读约 310 ms，说明是命令数而非带宽在限制 |
| 网络往返（QUIC） | 8–13 ms | 只在轮询模式里直接决定采样率 |

因此采样率上限 ≈ `1 / 单次读取时间`。一次读取可以合并同一 RAM 区域内的多个变量
（最多 128 个区间 / 64 KB），所以**变量数量几乎不额外花时间，时间轴才是瓶颈**。

### 两种手机侧节拍

- **定时**（`interval_ms` / `interval_us`）：手机按周期读取，读完补睡剩余时间。
  在本机只跑到请求值的 32–84%（100 Hz → 84 Hz、150 Hz → 118 Hz、200 Hz → 98 Hz），
  且会因为读取超时跳过周期（`skipped_ticks` 增长）。
- **全速**（`interval_ms=0`）：读完立刻读下一次，时间戳由手机如实给出，
  `skipped_ticks` 恒为 0。USB 流水线后本机稳定在 **368–371 Hz**，两条流聚合 525 Hz。

## USB 流水线（probe-rs 改动）

CMSIS-DAP 原来先等 OUT 传输完成、再提交 IN URB，每个命令多付一次提交/唤醒开销。
改成先挂 IN、再发 OUT（`usb_util::exchange_bulk_endpoints`，所有命令统一走
`CmsisDapDevice::exchange`）后，单次读取从 4.2 ms 降到 **1.7 ms**，已经贴近全速
USB 的理论下限（OUT 一帧 + IN 一帧）：

| 场景 | 流水线前 | 流水线后 |
| --- | --- | --- |
| 手机单次读取 | 4.1–4.4 ms | **1.7 ms** |
| 单变量全速 | 190–212 Hz | **368–371 Hz** |
| 两条流聚合 | ≤ 200 Hz | 525 Hz |

块读仍按 56 字节/次往返：这颗 Horco 固件收到 >64 字节的 `DAP_TransferBlock`
响应请求时会 STALL bulk IN 端点，因此 probe-rs 只能保持单包切块；`response_len`
机制保留给真正支持多包响应的探针。机器人固件未做任何修改。

## 电脑侧的处理

`RemoteMemoryBackend` 每 0.75 s 统计一次实际送达速率，据此为当前请求速率选择节拍
（`_evaluate_sampling_mode`）：

1. 目标速率 ≤ 60 Hz：始终用定时器，让探针在两次采样之间空闲。
2. 高于 60 Hz 时，先用定时器测一个已稳定的窗口（丢弃仍包含重新订阅的那个窗口）。
3. 定时器送达速率低于请求的 2/3 时切到全速：此时两种节拍里全速更接近请求值。
   每个请求速率只决策一次，两种模式不会来回抖动；速率变化超过 20% 会重新测量。
4. 手机不支持 `memory_sampling_max_speed`（旧网关）时保持定时器。
5. 周期短于 1 ms 时才使用 `interval_us`；≥ 1 ms 走手机的毫秒定时器（更稳）。

本机实测（请求 → 实际）：

| 请求 | 实际 | 节拍 |
| --- | --- | --- |
| 50 Hz | 46 Hz | 定时 |
| 100 Hz | 92 Hz | 定时 |
| 150 Hz | 112 Hz | 定时 |
| 200 Hz | 185 Hz | 全速 |
| 500 Hz – 5 kHz | 176–190 Hz | 全速 |

另外两处减少争用的改动：

- 目标运行且采样率 ≥ 200 Hz 时，`debug_status` 轮询从 50 ms 放宽到 250 ms。
  手机把所有探针操作串行在同一个工作线程上，状态轮询会直接抢走读取时间；
  在旧网关（定时 1 ms 周期）上实测，这一项把 1000 Hz 请求下的实际速率
  从 187 Hz 提升到约 240 Hz。
- 性能日志增加 `memorySamplingMode`（`full`/`timed`）与 `memoryPhoneReadUs`，
  直接显示“手机单次读取 X ms（全速/定时）”，据此可估算上限 `1000 / X` Hz。

## 想要更高采样率

按性价比排序：

1. **RTT（推荐）**：把变量放进 SEGGER RTT 上行缓冲，目标侧连续写入，手机按块搬运。
   一次 USB 命令可搬运上千字节，速率可达 kHz 级。该固件已链接 `_SEGGER_RTT`，
   在控制循环里调用 `SEGGER_RTT_Write` 即可；本项目已支持 RTT 可靠/实时优先两种投递。
2. **突发采样（需改协议）**：一次 DAP 命令带 N 个重复读（`DAP_Transfer` 的多请求），
   一次 USB 往返取回 N 个带时间戳的样本，可把单变量速率提高一个数量级。
   需要手机端 `ember-runtime` 与 `ember-v2` 的 `SampleRequest` 同时扩展。
3. **换探针**：全速 CMSIS-DAP 每个命令约 1–3 ms；高速探针（J-Link / 高速 CMSIS-DAP）
   可把单命令延迟压到百微秒级。手机 App 里也可以直接选 CMSIS-DAP v2（bulk）而不用
   v1（HID，1 ms 轮询间隔）。
4. **避免采集时让手机 App 停留在“连接”页**：该页的链路诊断会与采集争用同一个探针
   工作线程，实测会导致数秒级的采样空洞。

## 复现

```powershell
# 手机端订阅速率与单次读取耗时
python tool/diagnostics/ember_rate_probe.py

# 完整采样链路（服务、记录、发布）的有效速率
python tool/diagnostics/ember_service_rate.py --rates 100,200,500,1000 --seconds 6

# 只看手机定时器能达到多少（禁用全速升级）
python tool/diagnostics/ember_service_rate.py --rates 100,500 --seconds 6 --no-escalate
```
