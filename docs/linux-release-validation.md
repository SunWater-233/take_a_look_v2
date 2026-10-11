# Linux 0.1.0+1 / fd48238 发布验证

验证日期：2026-10-11（Asia/Shanghai）。发布文件：
`take-a-look-v2-0.1.0+1-git.fd48238-linux-x86_64.tar.gz`。

- 大小：72,443,838 字节，约 69.1 MiB。
- SHA-256：`2f048989950328495ba19d5b8c3353ca3437270dc03392b9bdc772a2d9f1e796`。
- 源码：`fd48238e57e33ece767dbd159152b005ea09ac81` 加本次安装、升级和打包修改。
- WSL 2 的 Ubuntu 内使用独立 Debian 11 用户空间编译，构建 glibc 为 2.31。
- 工具链：Flutter 3.44.1 / Dart 3.12.1、Python 3.11.17、Clang 11.0.1、PyInstaller 6.22.3。
- 同时编译并打包生产 Flutter 前端、原生插件、字体和独立 Python 后端。无需在目标电脑安装 Flutter 或 Python。
- 包内 73 个 ELF 文件经审计，最高 glibc 符号要求为 **2.30**；实际验证过的最老用户空间为 Debian 11 / glibc 2.31。
- 架构为 **x86_64**；本次没有生成 ARM、Windows 或 macOS 二进制包。

## 编译与测试

| 检查 | 结果 |
| --- | --- |
| 后端 pytest | 76 项通过、10 项跳过，另有 4 个 subtest 通过 |
| Flutter analyze | 无问题 |
| Flutter test | 256 项通过、1 项跳过 |
| 原生 GPU 选择测试 | 成功、失败、崩溃、超时与回退路径通过 |
| PyInstaller 与 Flutter Linux Release | 完整编译成功 |
| ShellCheck、Dart 格式、Git whitespace | 通过 |
| tar.gz 校验 | Linux 生成的 SHA-256 与 Windows 独立计算结果一致 |

后端跳过项需要外部 EmberMobile Rust loopback 程序或显式指定 ARM GDB；
Flutter 跳过项需要通过 `TAL_TEST_ELF` 指定实际固件。
这些集成验证未计入本次通过项。

## 同一发布包的跨发行版验证

| 用户空间 | 后端自检 / RPC | 安装、自动升级、卸载 | 图形启动 |
| --- | --- | --- | --- |
| Debian 11，glibc 2.31 | 通过 | 通过 | 通过 |
| Arch Linux rolling，glibc 2.44 | 通过 | 通过 | 通过 |
| Ubuntu 26.04.1，glibc 2.43 | 通过 | 普通用户通过 | 普通用户、只读程序目录通过 |

Arch 环境来自校验过的官方 2026.10.01 bootstrap，并通过 `pacman -Syu` 同步安装依赖。
三种环境共享 WSL 2 内核；图形检查使用 Xvfb、Openbox、xcompmgr 和 Mesa 软件 GL。
截图人工检查确认完整界面、中文字体和“本机硬件后端已启动”日志正常。

Ubuntu 首轮较早截取的画面不完整；将窗口及后端就绪后的等待延长到 15 秒后，
默认渲染路径连续复查正常。本包保留默认图形策略，未强制切换 Flutter 渲染器。

## 安装与数据保护

- 在含空格、中文的解压路径启动，清除外部 Python 和动态库环境变量后自检通过。
- 冻结后的实际后端成功加载 ELF/DWARF、CMSIS Pack、libusb、pyOCD 插件、
  pygdbmi、aioquic 及其原生扩展，并完成握手、状态查询和关闭 RPC。
- 安装前缀包含空格、中文、`$` 和 `%`，命令链接和 desktop 文件验证通过。
- 从 PATH 自动找到已有自定义安装，无需再次指定前缀；升级不会另建默认安装。
- 升级清理旧库，同时保留前端和旧后端目录中的原始采样文件。
- 卸载拒绝删除没有安装标记的目录；正常卸载将程序目录内的采样记录保存到前缀的
  `share/take-a-look/saved-recordings.*`。
- 普通用户启动只读目录中的程序时，启动器选择用户数据目录，并验证前端实际将
  `TAL_RECORDINGS_DIR` 传给独立后端。

## 文件与复查入口

发布文件、`INSTALL.md`、SHA-256、构建清单和本报告在 `build/releases/`。
包内也有 `INSTALL.md`、`BUILD-INFO.json`、Python/Flutter 依赖清单与许可证。

- 完整构建日志：`build/linux-release-build.log`。
- Arch / Ubuntu 安装验证：`build/linux-verify-arch.log`、`build/linux-verify-ubuntu.log`。
- 桌面截图与进程检查：`build/releases/validation/`，主要截图为
  `debian11.png`、`arch.png`、`ubuntu26-default.png`。
- 本机 WSL 的可复用构建环境保留在 `/opt/take-a-look-build/debian11`；
  Linux Flutter 缓存与 Windows Flutter 缓存隔离。
- 源码安装说明：`docs/linux-install.md`；通用重建入口：`tool/package_linux.sh`。

## 验证边界

Fedora、openSUSE、其他 Ubuntu/Debian 版本提供依赖安装映射，本次未逐一运行。
原生 Wayland、物理显卡、真实 USB 探针、硬件采样/写入和远程设备连接未做实机验证。
推荐 X11 或 XWayland；J-Link 专有运行库及 ARM GDB 可执行文件按需另外安装。
