# 桌面构建

统一入口为 `tool/build.py`，无需额外 Python 包。Windows 提供 PowerShell/CMD 包装，Linux/macOS 提供 Bash 包装。
编译当前工作区的代码，包含未提交改动；版本覆盖只写入隔离源码，不修改工作区的 `pubspec.yaml`。

云端三平台构建见 [GitHub Actions 接入与使用](github-actions.md)，macOS 本地构建见 [macOS 安装说明](macos-install.md)。

## 常用命令

Windows 项目根目录：

```powershell
# Windows Release：一次编译，同时生成 MSI 和 portable ZIP
.\tool\build.ps1

# 只生成某种包
.\tool\build.ps1 -Target windows -WindowsPackage msi
.\tool\build.ps1 -Target windows -WindowsPackage portable

# Windows 和 Linux 全部构建，指定版本（Linux 使用 WSL）
.\tool\build.ps1 -Target all -Mode release -Version '1.2.3+4'

# 单独构建 Linux，或生成调试包
.\tool\build.ps1 -Target linux -Version '1.2.3+4'
.\tool\build.ps1 -Target windows -Mode debug -WindowsPackage portable
.\tool\build.ps1 -Target linux -Mode debug

# 清理旧中间文件；也可以清理后开始构建
.\tool\build.ps1 -CleanOnly
.\tool\build.ps1 -Target all -Clean

# 查看将执行的命令，或检查工具链
.\tool\build.ps1 -Target all -DryRun
.\tool\build.ps1 -Target all -Check
```

执行策略限制 PowerShell 时，使用 `tool\build.cmd`，接受同样的参数。双击默认构建 Windows 两种 Release 包。
自动化调用 CMD 可设置 `TAL_NO_PAUSE=1` 关闭结束暂停。

Linux / WSL：

```bash
# 已配好 Linux 工具链的机器
bash tool/build.sh --target linux --native --mode release --version 1.2.3+4
bash tool/build.sh --native --mode debug

# 使用已准备的 Debian chroot（需 root，详见 Linux 安装文档）
sudo -E bash tool/build.sh --target linux --mode release

# 也可在任何系统直接调用同一 Python 入口
python3 tool/build.py --clean-only --dry-run
```

本地 Windows 的 `all` 表示 Windows MSI、portable ZIP 和 WSL Linux tar.gz；macOS 的 `all` 构建本机 macOS 包。
Linux 主机使用 `--target linux`。GitHub Actions 的 `target: all` 会分发到全部系统的原生 runner，包含 macOS 两种架构。

## 参数

| PowerShell | Python / Bash | 用途 |
| --- | --- | --- |
| `-Target windows/linux/macos/all` | `--target windows/linux/macos/all` | 需要相应的原生主机；默认当前系统 |
| `-Mode release/debug` | `--mode release/debug` | 默认 release |
| `-Version 1.2.3+4` | `--version 1.2.3+4` | 默认读取 pubspec.yaml；构建号可省略 |
| `-WindowsPackage all/msi/portable` | `--windows-package all/msi/portable` | 默认 all，仅控制 Windows 包 |
| `-Clean` | `--clean` | 编译前清理 build 中间文件 |
| `-CleanOnly` | `--clean-only` | 只清理，不编译 |
| `-DryRun` | `--dry-run` | 只预览动作，不写文件 |
| `-Check` | `--check` | 只检查构建环境 |
| `-SkipBuild` | `--skip-build` | 仅重新打包上次成功的 Windows 应用 |
| `-Distribution Ubuntu-24.04` | `--distribution Ubuntu-24.04` | 选择 WSL 发行版 |
| `-Native` | `--native` | 使用 Linux 主机工具链，跳过 chroot |
| `-KeepBuild` | `--keep-build` | 成功后也保留 Linux 临时目录 |
| `-Python <路径>` | `--python <路径>` | Windows 后端环境初始化解释器；PS 包装也用它启动入口 |
| `-Flutter <路径>` | `--flutter <路径>` | Windows Flutter 路径 |
| `-VcRuntimeDirectory <路径>` | `--vc-runtime-directory <路径>` | Windows x64 Release CRT 目录 |

`SkipBuild` 只适用于 `Target windows`，要求同一模式、完整版本号（含 `+build`）已经成功编译，不能和 `Clean` 一起用。
修改应用或后端源码后需完整构建。Linux 的 Flutter/Python 覆盖与 chroot 路径仍使用 [Linux 文档](linux-install.md) 中的环境变量。

## 产物与清理

三平台构建都会从固定版本、经 SHA-256 校验的上游 CMSIS-Pack 生成精简运行包。
内置支持范围为 STM32F103（29 个型号/变体）、STM32F4 全系列（360 个）和 STM32H7 全系列（166 个）。
运行包保留芯片描述、烧录算法、SVD、调试配置与许可文件，移除文档、例程、驱动源码及未引用资源；
三个 `.pack` 文件合计约 9 MiB。其他型号仍可通过芯片库导入完整支持包。

完整上游包缓存在 `build/tools/cmsis-packs/`，不会进入应用发布包，清理构建目录时保留。
`backend/bundled_packs/index.json` 分别记录原始 SHA-256 和精简文件 SHA-256；连接时校验实际发布文件。
旧版本使用原始内置包标识保存的受支持芯片选择会自动映射到精简包；用户自行导入的完整包继续独立管理。

```text
build/releases/<版本>/windows/               # Windows MSI、ZIP 和 SHA-256
build/releases/<版本>/linux/                 # Linux tar.gz、SHA-256、构建清单和安装说明
build/releases/<版本>/macos/                 # macOS app ZIP、DMG、SHA-256 和构建清单
build/logs/                                  # 编译与验证日志
build/tools/wix-5.0.2/                        # 可复用的工具缓存
build/work/windows/release/source/           # 隔离的 Windows Release 源码、构建结果
build/work/windows/debug/source/             # 隔离的 Windows Debug 源码、构建结果
```

每次完整 Windows 构建自动重建对应模式的隔离源码、Flutter/CMake 缓存及 PyInstaller 工作目录，
不再要求手动删目录。MSI 和 portable 使用同一次 Flutter/后端编译，分别生成更新清单并独立验证。
源码复制排除后端测试临时目录和采样文件；隔离源码内已有的采样目录会自动移到 `build/recordings/windows-<模式>-<时间>-<标识>/`，
保留相对路径和同目录元数据，然后继续构建。
成功后清除打包 staging、临时压缩包和 MSI 解包验证目录；失败时保留诊断文件。MSI 解包日志在 `build/logs/`，
直接运行 `verify_windows_msi.ps1 -KeepFiles` 可保留成功验证的解包目录。

Windows ZIP 和 Linux 包名保留完整版本（如 `1.2.3+4`）；Windows 未指定构建号时按 `+0` 处理。
MSI 文件名与内部 ProductVersion 使用 `1.2.3`，保持应用内更新的资源命名约定；EXE、更新清单和复用检查仍含构建号。
目录使用本次传入的版本文本，例如 `-Version 1.2.3+4` 输出到 `build/releases/1.2.3+4/windows/` 和
`build/releases/1.2.3+4/linux/`。省略构建号时两种系统均放入 `build/releases/1.2.3/`。
Debug 包名额外附加 `-debug`，不会覆盖同版本 Release 包；调试包用于开发，Windows Debug 程序需要本机 Visual Studio 调试运行库。
Debug 包保留 Windows PDB；Linux 清单的 `build_mode` 标明实际模式。

清理保留 `build/releases/`、`build/logs/`、`build/tools/`，以及任意层级的完整 `recordings/` 和独立 `*.talraw` 文件。
采样数据留在原路径，因此少数旧目录可能仍存在，其余中间文件已删除。清理不跟随符号链接或目录联接，
不会删除链接目标。发布包历史版本由你自行保留或删除。

原来的 `build_release_windows*` 和 `build_release_wsl*` 入口继续兼容；Windows 旧入口只选择对应包型，不再维护重复编译逻辑。
工具链配置和安装方式见 [Windows](windows-install.md)、[Linux](linux-install.md)。
