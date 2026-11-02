# J-Link 本地固件下载优化（2026-10-25）

使用用户指定的 `2026_wheel_legged_infantry_test/chassis/MDK-ARM/H7_Robot/H7_Robot.axf`，
原始文件 1,685,856 字节，ARM PT_LOAD 数据 139,216 字节，加载地址 `0x08000000`。
Keil 工程设备为 STM32H723VGTx；实测探针为 Segger J-Link CE，序列号 63728607。
AXF 的 SHA-256 为 `387894f7b81a5ba30dc29b7e889b365539788cee34eab048124e7d70ec95472f`。
所有测试均使用原 AXF，测试前后文件哈希和板上逐字节读回一致，结束时恢复运行。

## 原因与修改

未指定 `jlink.device` 时，pyOCD 的 J-Link 驱动使用低层 CoreSight 访问；
其 `read_ap_multiple` 实际逐字调用 DLL。大块内存读取仍会产生大量同步 USB 往返。
这与 [pyOCD 官方说明](https://pyocd.io/docs/debug_probes.html#segger-j-link) 一致。

内置 `stm32h723xx` 是 AP0 上的单个 Cortex-M7，现在通过 `jlink.device=Cortex-M7`
启用 pyOCD 已有的 `JLinkMemoryInterface`。pylink 连接时会选择自动速度，连接后重新
应用用户配置的 SWD 时钟。实测请求 4 MHz，DLL 的 `JLINKARM_GetSpeed` 报告 2000 kHz；
没有通过调高界面时钟取得以下收益。其他型号、芯片包和其他探针保持原连接设置。

下载先按实际擦除扇区分组，分块比较映像覆盖的字节，不读 ELF 未初始化区或扇区空隙。
完全相同的扇区不再运行烧录算法。变化扇区提交其全部映像数据，包括原本相同的页，
并关闭该次提交中的重复 smart-flash 比较。保留原有扇区擦除及 `keep_unwritten` 配置。
任何写入之后都重新逐字节校验整份映像，包括跳过的扇区。完全相同且没有写入时，
前面的完整比较即完成确认。比较读失败或短读发生在擦除前，不继续执行下载。

RAM、外部 Flash、不可直接读取的 Flash、编程页跨擦除扇区等情况沿用通用加载流程。
后端日志增加比较、擦写、写后校验时间以及跳过的扇区数。

## 板上测量

同一固件重复下载，三次结果；仅计 `program_firmware` 阶段，不包含符号重载：

| 路径 | 三次耗时（秒） | 中位数（秒） | 内存块读取调用 | 读取字节 |
| --- | --- | ---: | ---: | ---: |
| 原连接、原加载器 | 63.857 / 62.647 / 63.653 | 63.653 | 306 | 278,480 |
| 原连接、扇区比较优化 | 31.790 / 31.521 / 30.067 | 31.521 | 9 | 139,216 |
| 原生块传输、原加载器 | 3.230 / 3.219 / 3.247 | 3.230 | 306 | 278,480 |
| 原生块传输、扇区比较优化 | 1.551 / 1.528 / 1.506 | 1.528 | 9 | 139,216 |

最终路径中位数约提速 41.7 倍，两个相同扇区均跳过。这些是重复下载数据，
不能作为新固件完整擦写的耗时。

另外强制进入变化扇区分支，实际擦除两个扇区并重写原映像，擦写 8.197 秒、
完整写后读回校验 1.387 秒，总计 9.709 秒。本次测试通过测试钩子强制判定扇区变化，
比较阶段不计真实数据比较时间；没有构造或烧录修改过的测试固件。

Windows Release 目录中的打包后端也通过真实 stdio RPC 执行了下载、符号重载和
恢复运行，完整流程约 7.4 秒，其中 Flash 比较约 1.4 秒、下载核心约 1.5 秒。

原始日志和 JSON 保存在本机 `build/`：`local-firmware-jlink-benchmark.log`、
`local-firmware-jlink-results.json`、`local-firmware-jlink-native.log`、
`local-firmware-jlink-native-results.json`、`local-firmware-packaged-results.json`。
Debug / Release 目录的打包后端已更新。

## 验证

后端全套回归为 332 passed、25 skipped、4 subtests passed；打包后端自检通过。
新增测试覆盖完整相同映像、末尾非 FF 空隙、扇区中后部变化、同扇区分散数据、
保留未写入字节、跨扇区后的读取失败、短读、写后损坏以及被跳过扇区的意外损坏。
连接测试覆盖 J-Link 原生接口配置、时钟恢复以及其他目标/探针/芯片包的原有路径。
