# GitHub Actions 发行构建

`Desktop release` 工作流在 GitHub 原生 Windows、Linux 和 macOS runner 上构建发行包，不需要本机保持开机。
Windows/Linux 使用现有统一入口，macOS 由同一入口调用原生打包脚本。

## 手动构建

把工作流和脚本合并、推送到仓库默认分支后，打开 **Actions → Desktop release → Run workflow**：

| 参数 | 说明 |
| --- | --- |
| `target` | `all`、`windows`、`linux`、`macos`；macOS 自动构建两种 CPU 架构 |
| `mode` | `release` 或 `debug` |
| `version` | `1.2.3` 或 `1.2.3+4`；留空读取该分支的 pubspec.yaml |
| `windows_package` | `all`、`msi`、`portable`；只影响 Windows 任务 |

选择要构建的分支再运行。工作流先校验参数，随后并行运行所选平台。
手动按钮要求工作流先存在于默认分支；还没有合并时，可通过修改相关文件的 PR 自动验证。

完成后进入该次运行的 **Artifacts**，下载 `desktop-<版本>-<系统>-<架构>-<模式>`。
每份 artifact 内保持以下结构，Release 和 Debug 文件名不会冲突：

```text
<版本>/windows/   # MSI、portable ZIP、SHA-256
<版本>/linux/     # tar.gz、SHA-256、构建清单、安装说明
<版本>/macos/     # 原生 app ZIP、DMG、SHA-256、构建清单
```

各平台分别上传诊断日志，构建失败也可下载 `logs-...` artifact。
发行产物保留 14 天，日志保留 7 天；需要长期保存时可下载或上传到正式 GitHub Release。

## 标签构建

推送 `v<版本>` 标签会自动构建全部系统的 Release 包，版本取自标签，并覆盖隔离源码中的 pubspec 版本。
例如 `v1.2.3+4` 生成 `1.2.3+4/` 下的全部发行包。Windows MSI 版本范围限制仍适用。
该工作流上传 Actions artifacts，不自动创建或公开发布 GitHub Release。

## 平台环境

| 平台 | Runner / 环境 | Flutter |
| --- | --- | --- |
| Windows x64 | windows-2022；Python 3.11；.NET 8；VS C++；固定 WiX 5.0.2 | 3.47.8 |
| Linux x64 | ubuntu-22.04 上运行 Debian 11 容器；Python 3.11.17；glibc 上限 2.31 | 3.44.9 |
| macOS Apple Silicon | macos-15，原生 arm64 Python 3.11 / libusb | 3.47.8 |
| macOS Intel | macos-15-intel，原生 x64 Python 3.11 / libusb | 3.47.8 |

工具版本集中在 `tool/ci/release_config.py`、`tool/ci/linux.Dockerfile` 和工作流中。
Linux 容器从源码标签安装固定 Flutter SDK，构建镜像可缓存；打包时审计实际 glibc 需求。
CMSIS 芯片包复用经过 SHA-256 校验的缓存。虚拟环境和发行 staging 不跨平台缓存。

Intel macOS 的 cryptography 在 CI 中从源码构建并静态链接 OpenSSL，避免与 Python 自带的同名动态库冲突。
macOS 安装阶段不复用 pip wheel 缓存，防止重新使用此前生成的动态链接 wheel。

macOS 包目前是 ad-hoc 签名测试发行，包含独立后端；正式 Developer ID 签名、公证及应用内自动安装更新尚未接入。
硬件后端通过离线自检和 RPC 检查；真实 USB 探针连接、固件下载仍需在实体设备上验证。
更多信息见 [macOS 安装说明](macos-install.md)。

普通构建和 artifact 上传使用 GitHub 自动提供的权限，不需要手动设置 PAT 或 Apple 证书 Secrets。
现有 `Desktop build` 仍负责默认分支/PR 的分析、测试和 Debug 编译。
