# Linux 0.1.0+1 / 36f066f 发布验证

验证日期：2026-10-11（Asia/Shanghai）。产物：
`take-a-look-v2-0.1.0+1-git.36f066f-linux-x86_64.tar.gz`。

## 构建与兼容范围

- 在 WSL 2 内的 Debian 11 独立构建环境编译，使用 glibc 2.31、Clang 11、
  Flutter 3.44.9 / Dart 3.12.2、Python 3.11.17、PyInstaller 6.22.3。
- 已从 `origin/master` 拉取 8 个新提交，源码为
  `36f066f54f7665fb063433ddcf5a9da92eb9fd79`（加入 ELF 读取进度条）
  加本地 Linux 打包适配。旧工作区改动保存在 Git stash
  `c4d1f40d2012a2c489da6decb4233bfa1d62efde`，并已适配新版目录后恢复。
- 新包包含远程 GDB、EmberMobile v1/v2、日志清空及新版源码调试功能；
  包内 `BUILD-INFO.json` 记录完整源码提交，文件名包含短提交号以区分旧包。
- 包内包含前端、字体、Python 后端及运行库。最高 ELF glibc 符号要求为 **2.30**；
  本次实际验证的最老用户空间为 Debian 11 / glibc 2.31。
- 启动器不注入全局 `LD_LIBRARY_PATH`，后端库与图形驱动使用各自的加载路径。
- 当前交付架构为 **x86_64**。aarch64 仅提供原生构建脚本支持，未生成或验证 ARM 二进制。

## 已执行的验证

| 环境 | 后端与 RPC | 解压迁移、安装、升级、卸载 | 图形启动 |
| --- | --- | --- | --- |
| Debian 11 / glibc 2.31 | 通过 | 通过 | Xvfb + Mesa 软件 GL 通过 |
| Arch Linux rolling，2026-10-01 bootstrap 后同步仓库 | 通过 | 通过 | Xvfb + Openbox + xcompmgr + Mesa 软件 GL 通过 |
| Ubuntu 24.04 / glibc 2.39 | 通过 | 通过，另以普通低权限用户验证 | Xvfb + Openbox + xcompmgr + Mesa 软件 GL 通过 |

三种环境都运行同一份 Release 包；Arch 和 Debian 使用各自独立的用户空间，
共享 WSL 2 内核。这些结果不是物理机器上的显卡/USB 硬件兼容性认证。
Arch 和 Ubuntu 的图形检查在正常窗口管理会话中进行，
发布包保留 Flutter 3.44.9 的默认渲染策略。

- Flutter analyze 无问题；**161 项 Flutter 测试通过、1 项跳过**。
- 后端默认测试集 **53 项通过、10 项跳过，另有 4 个 subtest 通过**。
  跳过项包括未提供 EmberMobile Rust loopback 程序的 7 项验证，
  以及需要显式配置 GDB 的 3 项集成验证。额外 GDB 验证结果见下节。
- SDK 固定的 matcher、meta、test_api、vector_math 依赖在临时构建副本中匹配 3.44.9；
  原 Windows 工程锁文件未变，实际依赖完整记录在包内 `FLUTTER-PACKAGES.lock`。
- 从包含空格、中文的路径启动压缩包；清除外部 Python/动态库环境变量后自检通过。
- 自检实际加载 ELF/DWARF、CMSIS Pack、pylink、libusb，并检查 CMSIS-DAP、ST-Link
  插件和 JSON RPC 握手、状态查询、关闭。J-Link 专有运行库作为可选外部依赖报告。
- 新增的 `pygdbmi`、`aioquic`、QUIC 原生扩展及远程后端模块均在冻结后的实际程序中
  加载成功；这些检查无需外部 Python 环境、网络连接或 USB 硬件。
- 安装前缀包括空格、中文、`$`、`%`；desktop 文件检查通过；升级删除旧版本残留文件；
  卸载保护能拒绝删除没有安装标记的目录。
- 三种环境均观察到 Flutter 图形窗口与独立后端进程；截图确认中文按钮正常、日志中
  显示本机后端已启动。截图在发布目录的 `gui-arch.png`、`gui-debian11.png`、
  `gui-ubuntu24.png`。
- ShellCheck、Git whitespace 检查通过；沿用此前通过验证的 udev 规则。

## 额外 GDB 10 集成验证的限制

另在 Debian 11 使用 GDB 10.1 运行了可选集成测试。原始模拟 Cortex-M 目标没有实现
GDB 10 软件单步所需的软件断点，导致综合用例在单步时超时。为定位原因，临时测试适配器
补充了模拟目标的 `Z0/z0` 软件断点和命中停止响应，应用代码未作修改。
补充后单步检查通过，但同一用例在复位后的 PC 寄存器检查仍失败；其余 4 项 GDB 测试通过。

因此本包不宣称 GDB 10 全部远程调试行为已验证。该额外测试失败不影响 Release 编译、
离线自检和上述三种桌面启动检查；实际远程 GDB Server、复位及硬件采样仍需目标设备验证。
本地构建日志：`build/linux-latest-build.log`；额外验证日志：
`build/linux-gdb10-build.log`、`build/linux-gdb10-trace.log`、
`build/linux-gdb10-fixture-check.log`。

## 随打包修复的问题

- Linux 拖拽插件的注册函数被隐藏，导致 Release 链接失败；补齐导出标记。
- PyUSB 打包 hook 仅针对 Windows；加入 Linux libusb 收集与后端离线自检。
- 部分按钮、提示及独立文本绘制没有继承中文备用字体；显式使用包内 MiSans，
  并调整窄面板连接按钮的内边距。

## 未覆盖项目

Fedora、openSUSE、其他 Ubuntu/Debian 版本提供了依赖安装映射，但本次未逐一实机验证。
原生 Wayland、多种物理 GPU、实际 USB 探针连接、采样、写入及 J-Link RTT 尚未进行硬件测试。
日常使用推荐 X11 或 XWayland；J-Link 用户需另外安装 SEGGER 官方运行库。

安装命令和权限配置见同目录 `INSTALL.md`（源码中为 `docs/linux-install.md`）。
