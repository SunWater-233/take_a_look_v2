# Linux 0.1.0+1 / 868f1c3 发布验证

验证日期：2026-10-13（Asia/Shanghai）。发布文件：
`take-a-look-v2-0.1.0+1-git.868f1c3-linux-x86_64.tar.gz`。

- 大小：64,488,023 字节，约 61.5 MiB。
- SHA-256：`d371b1f78bd7e8ea82e129d7be2a554a5ca1ef06f386acb2b092613918815129`。
- 源码：`868f1c3543bbf965649d5346950af3cdf39a1001` 加当前工作区修改，包含源码工程设置、编译/下载工具和键鼠下拉菜单修正。
- 在 WSL 2 / Ubuntu 24.04.1 中使用 Debian 11 用户空间构建，构建环境 glibc 为 2.31。
- 工具链：Flutter 3.44.9 / Dart 3.12.2、Python 3.11.17、Clang 11.0.1、PyInstaller 6.22.3。
- 包含 Flutter Release 前端、原生插件、字体和独立 Python 后端；目标电脑不需要 Flutter 或 Python。
- 扫描包内全部 ELF 文件；其中 22 个文件引用 glibc 版本符号，最高要求为 **2.30**。本次验证过的最老用户空间为 Debian 11 / glibc 2.31。
- 架构为 **x86_64**。构建脚本支持在 aarch64 主机原生构建 ARM64 包，本次没有生成 ARM64、Windows 或 macOS 包。

## 构建检查

| 检查 | 结果 |
| --- | --- |
| 后端 pytest | 85 项通过、11 项跳过，另有 4 个 subtest 通过 |
| Flutter analyze | 无问题 |
| Flutter test | 264 项通过、1 项跳过 |
| 原生 GPU 选择测试 | 通过 |
| PyInstaller / Flutter Linux Release | 通过 |
| 发布包自检 | 后端依赖、RPC、安装、自动识别原安装并升级、记录保留、卸载保护通过 |
| 最终文件校验 | Linux SHA-256 与 Windows 独立计算结果一致 |

后端跳过项包括外部 EmberMobile loopback、未配置的 ARM GDB 集成检查及 Windows 专属命令解释器检查。
Flutter 跳过项需要通过 `TAL_TEST_ELF` 指定真实固件。

## 同一程序的跨发行版验证

| 环境 | glibc | 后端 / RPC | 安装、升级、卸载 | 图形启动 |
| --- | --- | --- | --- | --- |
| Debian 11 | 2.31 | 通过 | 通过 | 通过 |
| Arch Linux rolling，2026.10.01 bootstrap，已安装运行依赖 | 2.44 | 通过 | 通过 | 通过 |
| Ubuntu 24.04.1 | 2.39 | 通过 | 通过 | 通过 |
| Ubuntu 24.04.1，普通用户 UID 65534 | 2.39 | 通过 | 通过 | 通过 |

三种环境共享 WSL 2 内核，图形检查使用 Xvfb 和 Mesa 软件 GL；Arch 与 Ubuntu 还启动 Openbox、xcompmgr。
截图确认中文字体、完整界面以及“本机硬件后端已启动”日志正常。
普通用户环境验证不依赖 root 权限。临时测试会话有不影响结果的辅助功能 / dconf 警告。

## 真实旧包升级与新版编译功能

使用此前生成的 `take-a-look-v2-0.1.0+1-git.36f066f-linux-x86_64.tar.gz` 安装旧版本，
然后从新包运行 `install.sh --no-deps`，验证以下行为：

- 从 PATH 自动识别原来的自定义安装前缀，不额外创建默认安装。
- 保留已有采样记录和用户工程，清除过时的程序库。
- 安装路径包含中文、空格、美元符号及百分号时，启动入口和 desktop 文件仍然有效。
- 打包后的后端在 Bash 中执行编译命令，使用正确的中文工程工作目录，输出中文日志并生成测试产物。
- 编译失败返回正确退出码；取消编译会终止子进程；重启后恢复工程配置。

以上测试不连接硬件。产物是用于验证编译链路的测试文件，不代表完成真实固件编译或烧录。

跨发行版检查完成后，只更新了包内 `INSTALL.md`。逐文件比较确认所有程序、运行库、资产及权限均与已测版本一致；
最终 tar 包又通过了 Ubuntu 普通用户下的完整安装、旧包升级、编译 RPC 和图形启动检查。

## 结果与复查入口

发布文件、SHA-256、`INSTALL.md`、本报告及带版本名的 `BUILD-INFO.json` 位于 `build/releases/`。
包内也有实际构建使用的 Python / Flutter 依赖清单和许可证。

- 完整构建日志：`build/linux-release-current.log`。
- 各发行版日志及截图：`build/releases/validation-868f1c3/`。
- 本机 WSL 构建入口：`build/linux-current-build.sh`。
- 跨发行版检查入口：`build/linux-current-validate.sh`，参数为 `debian11`、`arch` 或 `ubuntu24`。
- 实际旧包升级和冻结后端验证：`build/verify_linux_current_release.py`。
- 可复用 Debian 构建环境：WSL 中的 `/root/.cache/take-a-look-linux/bullseye`。
- 本次 Linux Flutter SDK：`/root/.cache/take-a-look-linux/flutter-3.44.9`。
- 通用打包入口：`tool/package_linux.sh`；安装和升级说明：`docs/linux-install.md`。

## 验证范围

Fedora、openSUSE 等提供依赖安装映射，本次未逐一运行。
ARM64、原生 Wayland、物理显卡、真实 USB 调试器、固件烧录及远程设备连接尚未实机验证。
推荐 X11 / XWayland；J-Link 专有运行库及目标平台编译器、GDB 按需另外安装。
