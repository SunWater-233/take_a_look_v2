# Take A Look V2：Linux 安装与打包

发布文件为 `take-a-look-v2-<版本>-git.<提交>-linux-<架构>.tar.gz`，旁边的 `.sha256`
文件用于校验。包内包含 Flutter Release 程序、字体、Python 解释器、pyOCD、
ELF/DWARF 解析库、libusb 和安装脚本；使用者不需要安装 Flutter、Dart、Python 或 pip。

## 快速安装

把压缩包和校验文件放在同一目录，然后执行（把文件名换成实际下载的版本）：

```bash
sha256sum -c take-a-look-v2-0.1.0+1-git.868f1c3-linux-x86_64.tar.gz.sha256
tar -xzf take-a-look-v2-0.1.0+1-git.868f1c3-linux-x86_64.tar.gz
cd take-a-look-v2-0.1.0+1-git.868f1c3-linux-x86_64
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

Wayland 桌面（包括 niri）默认优先使用 GTK 原生 Wayland，无需为本程序安装 XWayland。
面板跨窗口拖动使用系统拖放协议；窗口初始位置由合成器决定。标签排序、组合、拆分和
侧栏／底部停靠继续可用，拖动预览由合成器显示。X11 会话继续使用原有窗口交互。

可用下面的命令明确选择后端进行对照排查；这些设置只影响本次启动：

```bash
GDK_BACKEND=wayland ./take-a-look
GDK_BACKEND=x11 ./take-a-look
```

在 Wayland 桌面选择 X11 后端时，仍需桌面提供 XWayland；niri 使用 xwayland-satellite。
启动器保留显式设置的 `GDK_BACKEND`。原生适配与验证范围见 [Wayland 说明](linux-wayland.md)。

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

本包包含远程 GDB、EmberMobile v1/v2、ELF 读取进度和当前源码调试界面；
包内带有 `pygdbmi`、`aioquic` 及相应运行库。GDB 可执行文件按上游设计由系统提供：
ARM/Cortex-M 目标使用 `arm-none-eabi-gdb` 或 `gdb-multiarch`，并在连接设置的 GDB 路径中指定。
不使用 GDB 模式时无需安装 GDB；EmberMobile 私有协议模式不依赖 GDB。
远端仍需先启动对应 GDB Server 或 EmberMobile 网关。

## 自检、升级、卸载

```bash
./take-a-look --doctor                 # 架构、glibc、图形库、USB 库、探针插件、RPC
./take-a-look --backend --self-test    # 只检查包内后端，不需要图形会话/探针
```

升级时先关闭主窗口和所有独立窗口，解压新版本，再运行相同的 `./install.sh`。
无需卸载旧版本。安装器按 PATH 中的 `take-a-look`、`~/.local/bin/take-a-look`、
`/usr/local/bin/take-a-look` 的顺序识别本应用的已有安装，在原位置完成升级，
并输出 `Upgraded`。有多个安装时用 `--prefix` 或 `--system` 明确选择要升级的版本。
系统目录需要管理员权限时，安装器会显示对应的 sudo 命令。
这里的升级是重新运行新包的安装脚本；应用不会自行下载或安装在线更新。

安装器先完成新包自检和临时目录复制，再替换程序；旧库会被清理，原有 `recordings/`
及旧后端目录内的采样记录会被保留，用户配置目录中的布局不会被改动。
源码工程的编译命令、解释器及固件路径保存在
`${XDG_CONFIG_HOME:-$HOME/.config}/TakeALook/source-projects.json`，升级时同样保留。
同一版本重复运行安装器也可修复安装。升级过程中请勿运行程序或同时运行多个安装器。

自定义安装位置可用 `./install.sh --prefix "$HOME/apps/tal"`；程序会放在该前缀的
`lib/take-a-look`，命令在 `bin/take-a-look`，菜单项在 `share/applications`。
自定义前缀可能不在桌面的 XDG 搜索路径中，这时直接运行该前缀下的命令即可。
系统安装可运行 `sudo ./install.sh --system --no-deps`，先由管理员安装依赖。
从应用菜单或 `take-a-look` 启动系统安装时，若程序目录不可写，采样记录自动写入
`${XDG_DATA_HOME:-$HOME/.local/share}/take-a-look/recordings`。也可设置
`TAL_RECORDINGS_DIR=/绝对路径` 指定采样目录，前端和后端会使用同一位置。
默认的用户安装与可写的便携目录仍在程序旁的 `recordings/` 保存记录。

```bash
~/.local/lib/take-a-look/uninstall.sh
```

卸载会先将程序目录中的采样记录复制到安装前缀的
`share/take-a-look/saved-recordings.*`，并打印具体位置；用户数据目录中的记录、
工作区布局及可被其他调试软件使用的 udev 规则也会保留。要移除本应用安装的规则：

```bash
sudo rm /etc/udev/rules.d/60-take-a-look-probes.rules
sudo udevadm control --reload-rules
```

## 从源码重建（Linux / WSL）

### 一键构建（WSL）

Windows 主入口是 **`tool/build_release_wsl.ps1`**，在项目根目录的 PowerShell 中运行：

```powershell
.\tool\build_release_wsl.ps1
.\tool\build_release_wsl.ps1 -Version 1.2.3  # 指定本次发布版本
.\tool\build_release_wsl.ps1 -Version '1.2.3+4'  # 可附带构建号
.\tool\build_release_wsl.ps1 -Check  # 只检查环境
.\tool\build_release_wsl.ps1 -Distribution Ubuntu-24.04
.\tool\build_release_wsl.ps1 -KeepBuild  # 成功后也保留中间目录
```

脚本自动定位工程，默认调用 WSL 的默认发行版；也可从其他工作目录使用脚本的完整
路径调用。双击 `tool/build_release_wsl.cmd` 会启动同一个 PowerShell 脚本并在结束后
暂停，便于查看结果；它只负责启动，不包含构建逻辑。CMD 入口接受相同的 PowerShell
参数，例如 `.\tool\build_release_wsl.cmd -Version 1.2.3`。

WSL 内直接运行：

```bash
bash tool/build_release_wsl.sh
bash tool/build_release_wsl.sh --version 1.2.3
```

`-Version` / `--version` 接受 `主版本.次版本.修订号`，可附加 `+构建号`。
省略时读取 `pubspec.yaml`。指定版本仅写入临时源码副本，用于 Flutter 应用构建、
压缩包名称及 `BUILD-INFO.json`；不会修改工作区的 `pubspec.yaml`。
例如 `1.2.3` 会生成 `take-a-look-v2-1.2.3-git.<提交>-linux-<架构>.tar.gz`。

PowerShell 入口在默认 chroot 模式下自动选择 WSL root 用户，以运行独立挂载
命名空间和 chroot；`-Native` 模式仍使用发行版的默认用户。直接在 WSL 普通用户
终端使用 chroot 时，请运行 `sudo -E bash tool/build_release_wsl.sh`。

默认依次查找 `<缓存>/bullseye`、`/root/.cache/take-a-look-linux/bullseye` 和
本机旧布局 `/opt/take-a-look-build/debian11`。Linux SDK 依次查找
`<缓存>/flutter-3.44.9`、`/root/.cache/take-a-look-linux/flutter-3.44.9` 和所选
chroot 内的 `/opt/flutter`。日志打印实际路径和 Flutter 版本。
chroot 内的 `/opt/tal-python-path` 保存 Python 3.11+ 可执行文件路径；
兼容旧环境缺少该文件时使用 `/opt/python311/bin/python3.11`。
脚本会检查已有环境，不会自动下载或安装系统环境；所有候选目录均不存在时需先
配置 Debian 11 环境，或使用已配好开发依赖的原生 Linux 环境。

可以用 Linux 环境变量 `TAL_LINUX_CACHE`、`TAL_LINUX_ROOTFS`、
`TAL_LINUX_FLUTTER_ROOT` 覆盖缓存、chroot 和 SDK 路径。默认以 `TAL_MAX_GLIBC=2.31`
检查发布包；临时挂载位于独立挂载命名空间，成功、失败或中断后均自动释放。
同一个工程或 chroot 同时只允许一个一键构建任务。

也可以通过环境变量选择 WSL 发行版；`-Distribution` 参数优先。
从终端或自动化中调用 CMD 双击入口时，可取消结束暂停：

```powershell
$env:TAL_WSL_DISTRO = 'Ubuntu-24.04'
$env:TAL_NO_PAUSE = '1'
.\tool\build_release_wsl.cmd
```

在已经配置 Linux Flutter SDK 和下文所列开发依赖的其他 Linux/WSL 主机上，可跳过
chroot，使用当前系统直接构建；此时 glibc 要求按实际工具链记录：

```bash
FLUTTER=/path/to/linux/flutter/bin/flutter PYTHON=python3 \
  bash tool/build_release_wsl.sh --native
```

构建使用当前工作区（包括未提交修改），在 Linux 临时目录编译，不改写 Windows
开发缓存。产物为 `build/releases/` 下的 `.tar.gz`、`.sha256`、`.BUILD-INFO.json`
和 `INSTALL.md`；完整日志为 `build/logs/linux-release-<时间>-<进程号>.log`。
任何检查或构建失败都会返回非零退出码，压缩包验证成功后才发布产物。
PowerShell 加 `-KeepBuild`、Bash 加 `--keep-build` 可保留成功构建的中间目录；
失败时中间目录始终保留。PowerShell 的 `-Native` 对应 Bash 的 `--native`。

### 手动配置与打包

实际 Flutter、Dart、Python 版本以包内 `BUILD-INFO.json` 为准。
Linux Flutter SDK 与 Windows 开发 SDK 使用独立缓存；必须检查所选 Linux 引擎的 glibc 要求。
需要 Linux 版 Flutter、Python 3.11+、Clang、CMake、
Ninja、pkg-config、GTK 3 开发库、libusb 开发库、rsync 和 binutils。
建议在 Debian 11 / glibc 2.31 构建环境中使用独立安装的 Python 3.11，扩大发行版覆盖。
可以用 WSL 内的 chroot/容器提供旧构建环境，而不替换主系统库。

```bash
export FLUTTER=/path/to/linux/flutter/bin/flutter
export PYTHON=/path/to/python3.11
export TAL_MAX_GLIBC=2.31
bash tool/package_linux.sh
# 指定版本（省略时读取 pubspec.yaml）：
bash tool/package_linux.sh --version 1.2.3
```

从 Windows 调用已经配置好的 WSL 构建环境时：

```powershell
wsl -d Ubuntu-24.04 -- env FLUTTER=/path/to/linux/flutter/bin/flutter bash /mnt/e/ProjectGarage/take_a_look_V2/take_a_look_v2/tool/package_linux.sh
```

确保 WSL 的 PATH 指向 Linux Flutter/Python，不要使用挂载的 Windows Flutter 缓存。
上面直接在 Ubuntu 中运行的命令会使用主机工具链；若要求 glibc 2.31 下限，
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
