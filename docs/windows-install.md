# Take A Look V2：Windows MSI 打包与安装

## Portable ZIP

在 Windows x64 项目根目录运行：

```powershell
.\tool\build_release_windows_portable.ps1
.\tool\build_release_windows_portable.ps1 -Version 1.2.3+4
```

也可以双击 `tool/build_release_windows_portable.cmd`，或给 CMD 入口传递相同参数。
脚本在 `build/windows_portable/` 中隔离构建应用和 Python 后端，将 x64 Visual C++
运行库一起打入 ZIP，并验证压缩包内每个文件的 SHA-256 及后端自检。产物和校验文件位于
`build/releases/`；工作区的 `pubspec.yaml` 不会被版本覆盖修改。

用户将 ZIP 解压到可写目录后运行 `take_a_look_v2.exe`。应保留完整目录结构；采样记录保存在
可执行文件旁的 `recordings/` 中，不包含在发布压缩包内。

## 一键构建

在项目根目录执行：

```powershell
.\tool\build_release_windows.ps1
```

或双击 `tool/build_release_windows.cmd`。双击入口会显示进度，并在结束后保留窗口；
自动化调用 CMD 时设置环境变量 `TAL_NO_PAUSE=1` 可关闭暂停。
PowerShell 执行策略阻止脚本时，也可以使用 CMD 入口。

构建电脑需要：

- Windows x64、Git 和项目的 Git 工作区。
- 满足 `pubspec.yaml` 要求的 Flutter SDK；`flutter doctor -v` 中 Windows 工具链正常。
- Visual Studio 的 **使用 C++ 的桌面开发**工作负载，含 Windows SDK、MSVC 和 C++ 运行库。
- Python 3.11+。已有 `backend/.venv` 时复用；缺少时自动执行后端环境安装脚本。
- .NET SDK 8 或更新版本，用于下载并运行 WiX。
- 首次下载 Flutter/Python/NuGet 依赖时需要网络。

脚本将 WiX Toolset **5.0.2** 和同版本 UI 扩展固定在 `build/tools/wix-5.0.2/`，
不会向全局安装 WiX 或修改系统 PATH。这个固定版本用于保持安装器配置和生成行为一致；
升级工具时需要同步更新脚本中的工具版本、扩展路径并重新验证安装器。

完整流程：

1. 读取 `pubspec.yaml` 中的版本并检查 x64 Visual C++ 运行库。
2. 将当前工作区源码（含未提交及未被 Git 忽略的新文件）复制到 `build/windows_msi/source/`。
3. 独立打包 Python 后端并编译 Flutter Windows x64 Release；不会覆盖正常开发构建或源码目录下的后端运行包。
4. 收集程序、字体、Flutter 资源、Python/pyOCD 依赖和 Visual C++ DLL，排除采样记录、日志和调试文件。
5. 运行后端离线自检，生成 MSI，并执行 WiX 的 MSI 一致性校验。
6. 将 MSI 管理性解包到带空格和中文的路径，逐个核对文件 SHA-256，再运行包内后端自检及 RPC 检查。
7. 全部通过后发布 MSI 和 SHA-256 文件。失败返回非零状态，保留之前成功的发布文件。

验证步骤不会注册应用、创建桌面快捷方式或连接硬件。解包文件和诊断日志保留在
`build/msi-verify-*/`，便于检查；这些目录可能占用较多空间。
项目目录过深时脚本会提示缩短路径，以避开 Windows Installer 的路径长度限制。

Windows 构建会将生成的应用、打包后端及受管理的虚拟环境 Python 设置为 Medium
完整性级别。这样即使工作目录带有 Low 标签，运行程序也能正常维护 AppData 下的
芯片库；不会修改工作目录或用户数据的访问权限。芯片库写入被拒绝时会立即显示错误，
并保留原选择和索引。

## 产物和参数

例如版本为 `0.1.0+1` 时：

```text
build/releases/Take-A-Look-V2-0.1.0-windows-x64.msi
build/releases/Take-A-Look-V2-0.1.0-windows-x64.msi.sha256
build/logs/windows-msi-<时间>.log
```

只调整安装配置、无需重新编译程序时：

```powershell
.\tool\build_release_windows.ps1 -SkipBuild
```

该参数只复用上次成功构建的独立 Release；要求其版本与当前 `pubspec.yaml` 一致。
修改 Dart、C++ 或 Python 代码后应执行完整构建，不能用 `-SkipBuild` 更新应用代码。

指定工具位置或 x64 Visual C++ CRT 目录：

```powershell
.\tool\build_release_windows.ps1 `
  -Python 'C:\Python311\python.exe' `
  -Flutter 'D:\FlutterSDK\flutter\bin\flutter.bat' `
  -VcRuntimeDirectory 'C:\path\to\x64\Microsoft.VC143.CRT'
```

`-Python` 仅用于首次创建后端虚拟环境。默认通过 Visual Studio 的 `vswhere` 定位 CRT；
手动指定时必须选择与构建工具链匹配的 **x64 Release** 运行库目录。

## 安装、升级和卸载

双击 MSI，在“安装位置”页直接输入路径，或点击“更改”浏览并选择文件夹，
例如 `D:\Applications\Take A Look V2`。默认目录为：

```text
%LOCALAPPDATA%\Programs\Take A Look V2
```

升级时会自动填入上次选择的安装目录。若升级时主动改到其他目录，已有采样记录仍保留在旧目录，
不会自动迁移；新记录保存在新安装目录的 `recordings/` 中。

安装仅面向当前用户，通常无需管理员权限，创建当前用户的开始菜单及桌面快捷方式。
目标电脑不需要 Flutter、Python、.NET SDK 或单独安装 Visual C++ 运行库。
使用 Windows 10/11 x64；ARM64 原生安装包不在这个脚本的构建范围内。

采样记录保存在安装目录中的 `recordings/`。安装器不打包、不删除该目录，
升级时保留记录；从 Windows“已安装的应用”卸载后，存在记录的目录会继续保留。
不要将应用安装到普通用户无法写入的目录，否则采样记录无法保存。

MSI 使用固定的 UpgradeCode。重打同一个三段版本时会替换同版本安装；
更高三段版本会升级，较低版本会被阻止。MSI 不比较 `+` 后的 Flutter build number，
因此正式发布升级时应增加 `major.minor.patch`，例如 `0.1.0+1` 改为 `0.1.1+2`。
三段范围分别为 `0..255`、`0..255`、`0..65535`。

可静默安装（在普通用户终端中运行，文件名按实际版本调整）：

```powershell
msiexec.exe /i "build\releases\Take-A-Look-V2-0.1.0-windows-x64.msi" /qn /norestart
```

首次静默安装时可以通过 `INSTALLFOLDER` 指定路径：

```powershell
msiexec.exe /i "build\releases\Take-A-Look-V2-0.1.0-windows-x64.msi" INSTALLFOLDER="D:\Applications\Take A Look V2" /qn /norestart
```

当前脚本生成未签名的 MSI；发布者证书签名未包含在这一步中。
GDB 仍是外部工具；J-Link 原生 RTT 需要按 SEGGER 的许可另行安装 J-Link 运行库。
安装包不修改探针驱动。

## 配置文件

- `tool/build_release_windows.ps1`：构建、收集文件、生成文件组件、打包和发布。
- `tool/build_release_windows.cmd`：双击入口。
- `tool/verify_windows_msi.ps1`：MSI 元数据、解包完整性和后端自检。
- `windows/installer/Package.wxs`：当前用户安装、升级标识、快捷方式及卸载规则。
- `windows/installer/UI.wxs`：中文向导流程。

安装器配置改动后，可以另外运行安装生命周期测试：

```powershell
.\tool\tests\windows_msi_lifecycle_test.ps1
```

该测试使用独立的随机产品名和 UpgradeCode、极小的测试文件，在 `build/` 内测试安装、
同版本替换、升级、降级拦截、过期文件清理和记录保留，结束时卸载测试产品。
它不会安装或卸载正式应用。请等构建完成后单独运行；Windows Installer 同时只能执行一个安装事务。

不要更换 `Package.wxs` 中的 UpgradeCode，否则 Windows 会将新包视作另一款应用。
文件组件标识由相对路径生成，重建和升级保持稳定；卸载只清理 MSI 管理的文件及空目录。

相关参考：[WiX 命令行](https://docs.firegiant.com/wix/tools/wixexe/)、
[WiX 安装界面](https://docs.firegiant.com/wix/tools/wixext/wixui/)、
[Flutter Windows 分发](https://docs.flutter.dev/platform-integration/windows/building)。
