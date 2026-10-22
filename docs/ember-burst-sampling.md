# Ember 突发采样（burst sampling）

单变量轮询受「一个样本 = 一次 USB 往返」限制：这颗 Horco CMSIS-DAP 是 USB 1.1
全速设备（`dumpsys usb` 显示 `version=1.00`，bulk 端点 64 字节），实测一次往返
4.1–4.4 ms，所以单样本上限约 200–240 Hz。要拿到 kHz，必须让固件自己按控制周期
采样，主机整块读回。

## 固件侧

`chassis/Application/Tasks/Src/chassis_task.c` 里新增 `tal_burst_buffer`：

```c
#define TAL_BURST_MAGIC     0x54414C31u /* "TAL1" */
#define TAL_BURST_CHANNELS  4u
#define TAL_BURST_CAPACITY  200u
#define TAL_BURST_PERIOD_US 1000u

typedef struct { uint32_t t_us; float value[TAL_BURST_CHANNELS]; } TalBurstEntry_t;
typedef struct {
    uint32_t magic, capacity, channels, period_us;
    volatile uint32_t head;                 /* 单调递增写计数 */
    TalBurstEntry_t entry[TAL_BURST_CAPACITY];
} TalBurstBuffer_t;
```

- 控制循环每 1 ms 调一次 `TalBurst_Push(&chassis_task.ins_data)`，写入
  `gyro[0..2]` 和 `yaw`；时间戳取自 `DWT->CYCCNT`，是真实采样时刻。
- 结构 4020 字节（20 B 头 + 200 × 20 B），200 ms 历史。
- 换通道只需改 `TalBurst_Push` 里的四个 `value[]` 赋值。

## 主机侧

1. 整块读：`read_memory_batch` 一次读 4020 字节；ADI 按 1 KiB TAR 窗口切成 4 条
   `DAP_TransferBlock`，每条一次 USB 往返。
2. 解码：`head` 增量即新样本数；`t_us` 差值即固件采样周期。
3. 参考实现：`tool/diagnostics/ember_burst_read.py`；块读吞吐用
   `tool/diagnostics/ember_block_read.py` 单独测。

## probe-rs 块读修复

vendor 的 probe-rs 原来把**每条命令的响应**限制在 `max_packet_size + 1`（65 B），
块读因此按 `(64-6)/4 = 14` 字（56 B）切块，4 KiB 要 74 次往返（实测 310 ms）。
修复后 v2 bulk 允许按请求长度分配响应缓冲（1 KiB 一条命令），并在设备不支持
多包响应时超时回退到单包：

- `probe/cmsisdap/commands/mod.rs`：`Request::response_len()` + 按需分配缓冲。
- `probe/cmsisdap/commands/transfer/mod.rs`：`TransferBlockRequest` 返回 `4 + 4*count`。
- `probe/cmsisdap/mod.rs`：`block_words`（v2 为 256 字），超时后回退并在本会话内记住。

## 验证

```powershell
# 手机解锁 → 打开探针（CMSIS-DAP v2 · Bulk）→ 启动服务
python tool/diagnostics/ember_block_read.py --bytes 4096 --rounds 20
python tool/diagnostics/ember_burst_read.py --seconds 5
```

预期：4 KiB 块读从约 310 ms 降到 20–40 ms；突发采样显示
`samples≈5000 rate≈1000/s firmware 1000Hz`，间隔抖动只有固件调度级别。
