# GDB 内存采样优化（2026-10-22）

在连接设置选择 **远程 GDB → 高速内存采样（只读）**，填写已有服务端地址和
端口即可，不需要配置本机 GDB 程序。原有 **断点调试** 模式保持默认，继续使用
GDB/MI 提供寄存器、断点、单步和写入等功能。

## 实现

- 采样直接使用标准 RSP `m地址,长度`，省去每次采样的 GDB 子进程、MI 命令和
  结果解析。仍只有一条服务端连接，不另开连接抢占探针。
- 协商 `QStartNoAckMode`；没有该能力时使用标准 ACK 模式。启用 TCP_NODELAY，
  按服务端 PacketSize 分块；支持粘包、拆包、校验和、转义和 RLE。
- 合并连续变量；间隔最多 128 字节、总长最多 512 字节的读取，只有完整范围位于
  `qXfer:memory-map:read` 明确标注的 RAM、且不与其他区域重叠时才能跨间隔合并。
  未提供内存映射、未知区域和 MMIO 不跨间隔读取。
- 不缓存变量值，不修改第三方服务端。协议错误、超时和断线不自动重发操作，
  不通过暂停/复位目标来掩盖运行中读取失败。
- 复用现有采样时钟、监视、暂停/继续、记录、清空和二进制发布链路。只读模式
  禁用变量写入、单步、复位、下载和断点；显式暂停/继续使用同一 RSP 连接。

`?` 并非可移植的实时运行状态查询，因此初始状态显示未知。本连接发出显式
暂停/继续或收到停止通知后才更新状态。其他工具改变目标状态时不能保证立即检测到。

Ember GDB Server 同时修复了接收侧：4 KiB 缓冲区接收并处理已有数据，省去逐字节
切换阻塞模式、读 socket 和更新服务状态；等待数据到来时直接唤醒，不再在空读后
额外休眠 10 ms。socket 的 10 ms 超时只用于退出检查和运行状态轮询，空闲时不忙等。
原有连接时暂停、断开策略、NACK 重发原响应和 Ozone 兼容处理保留。

## 服务端要求

标准读取范围来自 [GDB RSP 文档](https://sourceware.org/gdb/current/onlinedocs/gdb.html/Packets.html)。
不要求 Ember 私有扩展，但目标及服务端必须支持 CPU 运行中的后台内存读取。
分散且相距很远的变量仍需多次请求；跨变量读取也不是同一时刻的原子快照。

- **OpenOCD**：按目标配置启用后台访问。需要无暂停连接时，可参考官方
  [non-intrusive memory inspector](https://openocd.org/doc/html/GDB-and-OpenOCD.html#Using-GDB-as-a-non_002dintrusive-memory-inspector)
  配置 `gdb-attach` 事件。本文的直接 RSP 路径不依赖 GDB non-stop 模式。
- **pyOCD**：采样时建议关闭内存缓存，例如启动参数
  `-O cache.enable_memory=false`。参见 [缓存文档](https://pyocd.io/docs/gdbserver.html#caching)。
  已验证的 pyOCD 版本会在客户端连接时暂停核心；需要在工具栏显式继续运行。
- 服务端在连接或断线时执行的动作仍由各自配置控制。本客户端不会自动修改配置，
  也不会假定所有服务端能无暂停连接。

## 验证与边界

本机 Windows 回环 TCP + 模拟 RAM，同一服务端 fixture，每组 2 秒，3 个 uint32：

| 布局 | GDB/MI 调试读取 | 直接 RSP 读取 |
| --- | ---: | ---: |
| 连续 3 变量 | 66.4 Hz | 4123.4 Hz |
| 间隔 64 字节的 3 变量 | 24.4 Hz | 2633.9 Hz |

这些数字测量客户端开销，包含主机调度影响，不是 USB/SWD 或真实板上采样率，
不能套用为手机 Wi-Fi 链路的提速倍率。

最终 Windows 打包后端另经 stdio 加载真实 H7_Robot.axf，选择 3 个相距至少
64 字节的 float 地址，连接回环模拟 RAM：完整记录/二进制发布链路 5 秒收到
8527 帧，约 1701.8 Hz，各秒窗口 1663.5–1749.3 Hz，无错误。该测试验证打包和
生产采样链路，内存内容仍是模拟数据，同样不代表板上速度。

回归测试覆盖标准 ACK、NoAck、分块、RLE、错误响应、不重放、RAM 合并边界，
以及采样服务的记录、暂停、继续、清空、显式暂停目标/继续运行。
实际安装的 pyOCD GDB Server 使用模拟核心运行，验证真实协议栈的 NoAck、内存图、
连续不同读值和显式继续。真实 ARM GDB 与 Ember Server 的原有调试功能也通过回归。

OpenOCD 的 dummy adapter + ARM 模拟目标在客户端接入时触发 OpenOCD 自身断言，
因此该实验不计为兼容性通过；OpenOCD 的物理探针/目标验证仍待完成。

本次手机 USB 探针为 Horco，VID FAED / PID 4870，序列号 102021330500，与上轮
私有协议测速使用的探针不同。旧版和新版恢复连接时均遇到
`Arm(NoTargetResponse { source: Dap(NoAcknowledge) })`，4 MHz 和 1 MHz 旧版均复现。
没有下载、复位或修改 MCU 固件。本次没有新的板上 GDB Hz 结论。

## 复测

```powershell
# 源码后端：单变量或多个分散变量，输出 Hz、P95 延迟和本进程 CPU 成本。
backend/.venv/Scripts/python.exe tool/diagnostics/gdb_memory_rate.py --host 192.168.1.44 --port 3333 --address 0x24000000 --variables 3 --stride 64 --seconds 10

# 完整采样服务和记录/发布链路；如服务端连接时暂停，显式加入 --resume。
backend/.venv/Scripts/python.exe tool/diagnostics/gdb_memory_rate.py --host 192.168.1.44 --port 3333 --address 0x24000000 --variables 3 --stride 64 --seconds 10 --service --resume
```

`cpu_one_core_percent` 是本进程 CPU 时间 / 墙钟时间，不包含独立运行的服务端、
GDB 子进程或手机 CPU。示例地址和参数需与实际目标匹配。断线后的目标行为由服务端控制。
