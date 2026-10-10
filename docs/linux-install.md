# Take A Look V2：Linux 安装与打包

发布文件为 `take-a-look-v2-<版本>-git.<提交>-linux-<架构>.tar.gz`，旁边的 `.sha256`
文件用于校验。包内包含 Flutter Release 程序、字体、Python 解释器、pyOCD、
ELF/DWARF 解析库、libusb 和安装脚本；使用者不需要安装 Flutter、Dart、Python 或 pip。

## 快速安装

把压缩包和校验文件放在同一目录，然后执行（把文件名换成实际下载的版本）：

```bash
sha256sum -c take-a-look-v2-0.1.0+1-git.36f066f-linux-x86_64.tar.gz.sha256
tar -xzf take-a-look-v2-0.1.0+1-git.36f066f-linux-x86_64.tar.gz
cd take-a-look-v2-0.1.0+1-git.36f066f-linux-x86_64
./install.sh --udev
```

安装后从应用菜单打开 **Take A Look V2**，或执行：

```bash
~/.local/bin/take-a-look
```

默认安装到 `~/.local/lib/take-a-look`，无需用 sudo 运行整个安装器。
发现缺失的图形库时，安装器会调用发行版包管理器，并通过 sudo 请求系统权限；
`--udev` 为常见 USB 调试器安装权限规则，同样需要 sudo。安装完规则后重新插拔探针。
Arch 使用 `pacman -Syu --needed`，会正常同步升级系统，避免 Arch 不支持的部分升级。
已有完整桌面依赖时，应用本身可以离线安装、离线启动。

不使用 USB 硬件时可省略 `--udev`。依赖和权限规则已由管理员配置时：

```bash
./install.sh --no-deps
```

也可以不安装，直接从解压目录启动：

```bash
./take-a-look --doctor
./take-a-look
```

必须保留整个解压目录，不能只拷贝其中的可执行文件。

## 发行版与架构

以包内 `BUILD-INFO.json` / `runtime-requirements` 记录的实际架构、glibc 下限为准。
本项目的打包流程可在较老的 Linux 环境中运行，并审计包内全部 ELF 文件的 glibc 符号要求。
glibc 只是兼容条件之一，还需要下列桌面库和可用的 GL/EGL 驱动。

| 系统 | 运行时依赖安装 |
| --- | --- |
| Arch Linux / EndeavourOS / Manjaro | `sudo pacman -Syu --needed gtk3 libglvnd libusb systemd-libs xdg-utils` |
| Debian / Ubuntu / Linux Mint | 运行 `./install-deps.sh`，自动选择 `libgtk-3-0` 或 `libgtk-3-0t64` |
| Fedora / RHEL 系 | `sudo dnf install gtk3 libglvnd-glx libglvnd-egl libstdc++ libusb1 systemd-libs xdg-utils` |
| openSUSE | `sudo zypper install libgtk-3-0 libGL1 libEGL1 libstdc++6 libusb-1_0-0 libudev1 xdg-utils` |

这些是安装器支持的包管理器映射；实际验证过的发行版见随发布文件提供的验证记录。
已有 GTK 3 桌面的系统通常只需要解压或运行安装器。
`x86_64` 包适用于 Intel/AMD 64 位 Linux，不适用于 ARM。构建脚本同时支持在
`aarch64` Linux 主机上原生生成 `aarch64` 包，但 x86_64 WSL 构建不构成 ARM 验证。
Alpine/musl、32 位 Linux、Windows 和 macOS 不能直接运行这个 Linux tar 包。
Windows/macOS 需要分别在对应系统构建前端和 Python 后端。

## 显示与 GPU

推荐 X11 或带 XWayland 的 Wayland 桌面；多窗口插件包含 X11 操作，因此启动器在
存在 `DISPLAY` 时默认使用 XWayland/X11。Arch Wayland 用户请确保已安装
`xorg-xwayland`，且合成器启用了 XWayland。原生 Wayland 可以用
`GDK_BACKEND=wayland ./take-a-look` 尝试，但不承诺全部窗口管理功能可用。

图形驱动由系统提供，不打包 glibc 或显卡驱动，以便使用系统的 Mesa/NVIDIA 驱动。
请在有窗口管理器的正常桌面会话中运行；只启动 X server 的裸环境不作为支持的桌面配置。
排查黑屏或显卡选择问题时：

```bash
TAKE_A_LOOK_GPU=system ./take-a-look
./take-a-look --software-rendering
```

软件渲染选项使用系统 Mesa 软件 GL，仍需要图形会话和 Mesa 驱动。
可选的 `switcheroo-control` 用于自动选择独立显卡，缺少它也可以启动。

## USB 调试器与 J-Link

包内 `60-take-a-look-probes.rules` 为 ST-Link V2/V3、Arm DAPLink、Raspberry Pi
Debug Probe、部分 NXP 探针配置 `uaccess`。通过 systemd-logind 授权当前本地图形会话，
不把 USB 设备设置成全员可写。不使用 systemd-logind 的系统、远程 SSH 会话及自定义
CMSIS-DAP USB VID/PID，需要管理员按照探针厂商说明配置权限。

手动安装规则：

```bash
./install-udev.sh
```

J-Link 的原生 RTT/连接还需要从 [SEGGER 官网](https://www.segger.com/downloads/jlink/)
安装对应架构的 J-Link Software and Documentation Pack；其专有运行库不在本包中再分发。
首次使用没有内置支持的芯片时，也可能需要另外安装相应 CMSIS Device Family Pack。

WSL 可以编译并通过 WSLg 启动界面；使用真实 USB 调试器还需要 Windows 主机向 WSL
转发 USB 设备。没有连接硬件时，自检通过只说明运行库和协议正常，不代表完成了采样验证。

## 远程 GDB 与 EmberMobile

`36f066f` 版本包含远程 GDB、EmberMobile v1/v2 和 ELF 读取进度功能；
包内带有 `pygdbmi`、`aioquic` 及相应运行库。GDB 可执行文件按上游设计由系统提供：
ARM/Cortex-M 目标使用 `arm-none-eabi-gdb` 或 `gdb-multiarch`，并在连接设置的 GDB 路径中指定。
不使用 GDB 模式时无需安装 GDB；EmberMobile 私有协议模式不依赖 GDB。
远端仍需先启动对应 GDB Server 或 EmberMobile 网关。

## 自检、升级、卸载

```bash
./take-a-look --doctor                 # 架构、glibc、图形库、USB 库、探针插件、RPC
./take-a-look --backend --self-test    # 只检查包内后端，不需要图形会话/探针
```

升级时关闭程序，解压新版本，再运行 `./install.sh`，安装器会整体替换原程序目录。
自定义安装位置可用 `./install.sh --prefix "$HOME/apps/tal"`；程序会放在该前缀的
`lib/take-a-look`，命令在 `bin/take-a-look`，菜单项在 `share/applications`。
自定义前缀可能不在桌面的 XDG 搜索路径中，这时直接运行该前缀下的命令即可。
系统安装可运行 `sudo ./install.sh --system --no-deps`，先由管理员安装依赖。

```bash
~/.local/lib/take-a-look/uninstall.sh
```

卸载保留工作区数据及可被其他调试软件使用的 udev 规则。要移除本应用安装的规则：

```bash
sudo rm /etc/udev/rules.d/60-take-a-look-probes.rules
sudo udevadm control --reload-rules
```

## 从源码重建（Linux / WSL）

本次发布采用 **Flutter 3.44.9 / Dart 3.12.2**，重建时建议使用相同版本。
需要 Linux 版 Flutter、Python 3.11+、Clang、CMake、
Ninja、pkg-config、GTK 3 开发库、libusb 开发库、rsync 和 binutils。
建议在 Debian 11 / glibc 2.31 构建环境中使用独立安装的 Python 3.11，扩大发行版覆盖。
可以用 WSL 内的 chroot/容器提供旧构建环境，而不替换主系统库。

```bash
export FLUTTER=/path/to/flutter-3.44.9/bin/flutter
export PYTHON=/path/to/python3.11
export TAL_MAX_GLIBC=2.31
bash tool/package_linux.sh
```

从 Windows 调用已经配置好的 WSL 构建环境时：

```powershell
wsl -d Ubuntu-24.04 -- bash /mnt/e/ProjectGarage/take_a_look_V2/take_a_look_v2/tool/package_linux.sh
```

确保 WSL 的 PATH 指向 Linux Flutter/Python，不要使用挂载的 Windows Flutter 缓存。
上面直接在 Ubuntu 24.04 运行的命令会使用主机工具链；若要求 glibc 2.31 下限，
必须在旧版 chroot/容器内运行，并设置 `TAL_MAX_GLIBC=2.31` 作为发布门槛。
未设置这个变量时，脚本按实际检测的 glibc 要求写入清单，不宣称旧系统兼容。

脚本在临时 Linux 目录复制源码，排除 Windows 的 `.venv`、runtime 和 Flutter 缓存，
执行后端测试、Flutter analyze/test、PyInstaller 和 Flutter Release 构建，生成 tar.gz、
SHA-256 和依赖清单，并对压缩包做解压迁移、安装、升级、卸载验证。
输出默认在工程的 `build/releases/`；`TAL_OUTPUT_DIR` 可修改输出位置，
`TAL_KEEP_BUILD=1` 可保留中间产物。构建失败时中间目录自动保留，方便排查。
Flutter SDK 固定的依赖只在临时副本内解析，原工作区的 `pubspec.lock` 不被改写；
发布包中的 `FLUTTER-PACKAGES.lock` 是实际构建使用的锁文件。

依据：[Flutter Linux 发布](https://docs.flutter.dev/deployment/linux)、
[PyInstaller 的 Linux 兼容性说明](https://pyinstaller.org/en/stable/usage.html)、
[pyOCD Linux 权限规则](https://github.com/pyocd/pyOCD/blob/main/udev/README.md)、
[Arch GTK 3 包](https://archlinux.org/packages/extra/x86_64/gtk3/)。
