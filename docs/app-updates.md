# 应用内更新

点击主窗口左上角 **Take A Look** 品牌图标打开“关于与更新”。窗口提供当前版本、
**自动检测更新** 开关、手动检查、更新说明、忽略版本、下载进度和重启安装。
开关和忽略版本保存在用户配置目录的 `TakeALook/updates.json`，独立于项目文件。

发布版仅由主窗口在启动后检查一次，同一台机器每 24 小时最多自动检查一次；
手动检查始终可用。开发/调试构建不会自动请求 GitHub。后台失败不打断采集，
打开更新窗口可查看错误并重试。自动检测开关控制检查；下载和安装由用户点击触发。

## 发布要求

默认仓库为 `SunWater-233/take_a_look_v2`，读取公开的 GitHub Release
`/repos/{owner}/{repo}/releases/latest`。无需在客户端保存 GitHub Token。
只接受正式发布，忽略草稿、预发布以及 `-rc` 等预发布标签。
构建时可用 `--dart-define=TAL_UPDATE_REPOSITORY=owner/repo` 更换仓库。

1. 使用现有脚本构建完整包，版本例如 `1.2.3+4`。
2. 创建标签 `v1.2.3`（或 `1.2.3`）的正式 Release，填写更新说明。
3. 上传对应安装包及脚本生成的同名 `.sha256` 文件。也支持 GitHub API 返回的
   `sha256:` 资源摘要；缺少可用校验值时拒绝自动安装。
4. 确保 Release 标记为 Latest，且每种系统/架构/包类型只有一个匹配资源。
   更新比较忽略 `+构建号`，正式升级需要增加三段版本。

支持的资源名称：

| 类型 | 示例 |
| --- | --- |
| Windows x64 MSI | `Take-A-Look-V2-1.2.3-windows-x64.msi` |
| Windows x64 便携包 | `Take-A-Look-V2-1.2.3+4-windows-x64-portable.zip` |
| Linux x64 | `take-a-look-v2-1.2.3+4-git.abcdef0-linux-x86_64.tar.gz` |
| Linux ARM64 | `take-a-look-v2-1.2.3+4-git.abcdef0-linux-aarch64.tar.gz` |

Linux 文件名中的构建号和 `-git.<提交>` 后缀均可省略。
MSI 安装版始终选择 MSI，便携版始终选择 ZIP。

## 安装与恢复

Windows/Linux 打包脚本现在会编译独立的 `take_a_look_updater[.exe]`，并生成
`UPDATE-MANIFEST.json`，记录版本、架构、安装类型及受包管理的文件。
请重新完整构建首个支持更新的发布包。旧版包、普通 Flutter 开发构建、缺失清单或
更新程序的目录提供检测和发布页入口；自动安装需要完整的新版打包产物。
macOS 目前提供检测和发布页入口，尚无对应的自动安装打包流程。

更新包流式下载到系统临时目录，支持取消和重试；通过大小及 SHA-256 校验后才出现
“重启并更新”。独立程序再次验证校验值，检查清单、包类型和版本。MSI 还会只读检查
固定 UpgradeCode 与 ProductVersion，避免安装其他产品或错误版本。
Linux 在切换前执行新版包的 `--doctor`，验证平台和运行库。

点击重启安装后，工作区保存到独立快照，保留尚未保存的变量、输入草稿和布局，
不会覆盖用户的 `.talproj`。运行中的构建、固件下载及符号加载会阻止重启更新。
后台硬件进程完成关闭后，主进程退出，一并关闭所有浮动窗口。
更新程序需要收到本次安装尝试的提交标记，并确认主进程已经退出，才会安装。
每次重试使用独立握手目录；失败的旧尝试不能接收新尝试的提交。

- **MSI**：调用 Windows Installer 覆盖升级，保留原安装目录，记录安装日志，
  禁止安装器自行重启操作系统。安装失败沿用 Windows Installer 的回滚机制。
- **便携包/Linux**：在同文件系统的相邻目录准备新版，按旧清单移除过时程序文件，
  保留所有不属于旧程序包的文件，包括记录、项目和用户配置。
  用户文件与新版程序路径冲突时中止更新。目录切换失败会恢复原目录。
- **Linux 系统安装**：目录不可写时通过 `pkexec` 请求管理员授权；缺少 polkit
  时提示手动安装。权限不足或授权取消后保留旧安装。

便携包和 Linux 成功升级后保留完整的 `.take-a-look-backup-*` 相邻目录，
备份路径可在更新窗口查看。确认新版正常后可手动清理备份和临时下载目录。
重新启动会恢复更新前的工作区，设备保持断开，不会自动开始采集或写入变量。
结果保存在用户配置目录 `TakeALook/update-result.json`，安装失败会显示通知；
安装日志、快照及下载包保留在结果注明的临时目录，便于排查。

## 验证

```powershell
flutter analyze
flutter test
dart run tool/tests/update_helper_lifecycle_test.dart
# 只读校验现有 MSI，不执行安装：
dart run tool/tests/update_msi_preflight_test.dart build/releases/Take-A-Look-V2-1.2.3-windows-x64.msi 1.2.3
```

生命周期测试编译小型替身应用和真实独立更新程序，在临时中文/空格路径测试提交等待、
主进程退出等待、程序替换、采样记录保留、旧文件清理、完整备份及重新启动。
不会安装或卸载正式应用。
