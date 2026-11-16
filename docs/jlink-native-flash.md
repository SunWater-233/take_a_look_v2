# J-Link 官方 Flash 下载与本地烧录模块划分

本地 J-Link（包括使用 J-Link 驱动的 SAM-ICE）现在通过已有的 `pylink` 句柄调用
SEGGER DLL 的 `JLINK_DownloadFile`，使用 SEGGER 提供的 Flash Loader。
Python 的 `pylink-square` 仍是第三方封装；擦除与编程由 SEGGER 官方动态库完成。
其他本地探针继续使用 pyOCD 的内置或 DFP 算法。

## 芯片选择

烧录需要安装的 SEGGER DLL 能识别具体芯片名称。连接配置保留芯片库中的
`partNumber`，优先按完整型号查 DLL；STM32 DFP 中的 `STM32H723VGTx` 等名称
允许去掉封装后缀 `Tx` 后匹配 `STM32H723VG`。完整名称仍优先。

`stm32h723xx`、通用 Cortex-M 等不能确定具体芯片的名称会报错。使用芯片库选择
具体型号，必要时导入对应 DFP；也需要安装支持该型号的 J-Link 软件版本。
不根据相近名称猜芯片，不在原生下载失败后自动换用 pyOCD 算法重试。
选择 DFP 在这里仍提供内存范围和调试定义，J-Link 擦写不要求该包提供 pyOCD 算法。

## 下载流程

1. 检查 ARM ELF/AXF 的所有非空 `PT_LOAD` 段、物理加载地址、重叠和目标内存范围。
2. 查询 DLL 的具体芯片名称。以上检查失败不会连接或复位下载目标、执行擦写。
3. 仅把检查通过的 Flash 数据生成临时 Intel HEX，一次提交所有分散段，避免同一
   扇区的数据被拆成多次独立烧录。原始 ELF/AXF 仍用于符号和源码信息。
4. 复用现有探针句柄，设置具体芯片和用户时钟，复位并暂停，再调用官方 Flash 下载。
   未覆盖字节的保留设置沿用会话的 `keep_unwritten`。
5. Flash 算法结束后加载 RAM 段，避免下载算法的工作 RAM 覆盖已经加载的数据。
6. 通过 DLL 按原始加载段逐字节读回校验全部数据，含 RAM。校验失败不会报告成功，
   服务层不会执行下载成功后的复位与运行。

原生操作前后发送 pyOCD 复位通知，清除 DP SELECT/AP CSW 缓存；离开下载入口时
清除监视读取计划。进度使用 DLL 的比较、擦除、编程和校验阶段，再完成独立读回校验。
日志区分 J-Link 原生下载耗时与主机读回校验耗时，不推算 DLL 未提供的跳过扇区数量。

## 重构取舍

服务层已有 `TargetBackend.program_firmware(path, progress)`，承担暂停采样与 RTT、
移除断点、下载、重载符号和恢复运行的流程，继续作为统一入口。

本次只把本地烧录实现从内存后端拆出：

- `local_firmware.py`：公共固件地址检查、逐字节校验，以及 pyOCD 扇区比较辅助函数。
- `pyocd_flash.py`：已有 pyOCD 烧录、相同扇区跳过和校验流程。
- `jlink_flash.py`：SEGGER 设备名称解析、原生下载、RAM 加载和校验流程。
- `PyOcdMemoryBackend`：按实际探针驱动选择本地烧录实现，保留会话生命周期的所有权。

现有函数边界足够表达两种本地引擎，不再引入抽象基类、注册表或另一套会话。
Ember 手机和 GDB 已经通过相同服务入口使用各自的协议，保留现有模块边界。

## 验证范围

自动化测试使用模拟目标和原生接口，覆盖分散 Flash 段、跨 64 KiB 的 HEX 地址、
RAM 写入顺序、芯片名称、无 pyOCD 算法的原生路径、失败不回退、短读/错误读回、
短 RAM 写入、缓存通知、下载失败后的服务状态，以及原有 pyOCD 扇区优化回归。

本机实际 SEGGER DLL 已进行只读设备查询，确认 `STM32H723VGTx` 和 `STM32F103C8Tx`
能分别匹配 `STM32H723VG` 和 `STM32F103C8`，并存在 `JLINK_DownloadFile` 导出。
本次没有执行真实板上的擦写或下载速度对比。

参考：[SEGGER Flash download](https://kb.segger.com/UM08001#Flash_download)、
[SEGGER 命令字符串](https://kb.segger.com/J-Link_Command_Strings)、
[PyLink 下载接口](https://pylink.readthedocs.io/en/latest/pylink.html#pylink.jlink.JLink.flash_file)。
