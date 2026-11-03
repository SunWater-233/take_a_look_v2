# macOS 安装与构建

发行包按 `build/releases/<版本>/macos/` 分类，分别提供 Apple Silicon (`arm64`) 和 Intel (`x64`) 的 ZIP、DMG、SHA-256 和构建信息。
选择与电脑 CPU 对应的版本，Release 用于正常运行，带 `-debug` 后缀的包用于开发。

打开 DMG，将 `take_a_look_v2.app` 拖入 Applications；也可解压 ZIP 后移动整个 `.app`。
包内包含独立 Python/pyOCD 后端、libusb 和 STM32 官方芯片包，目标电脑不需要安装 Python、Flutter 或 Homebrew。
GDB 和 SEGGER J-Link 软件仍需按使用场景单独安装。

当前 CI 生成 **ad-hoc 签名、未经 Apple 公证**的包，适用于测试发行。
通过网络下载时 macOS 可能阻止打开；确认下载来源后，可在系统设置的“隐私与安全性”中批准打开。
面向公众的 Developer ID 签名及 Apple 公证需要后续配置开发者证书和凭据。

直接发行的隔离构建会关闭 App Sandbox，以启动硬件后端并访问 USB 探针。
原工程的开发签名与沙箱配置不被改写。采样记录统一写入：

```text
~/Library/Application Support/Take A Look V2/recordings/
```

替换或删除 `.app` 不影响该目录。`TAL_RECORDINGS_DIR` 可覆盖保存位置。
点击左上角 **Take A Look** 可打开“关于与更新”，启用或关闭自动检测，下载 GitHub
Release 中与当前安装架构对应的正式 ZIP，并在保存工作区、关闭硬件后端后安装重启。
首次需安装包含独立更新程序的新包，之后即可应用内更新；DMG 仍用于首次安装。
更新过程校验包摘要、应用标识、版本、架构及代码签名，整包替换 `.app` 并保留旧包备份，
不影响 Application Support 中的采样记录。目标 Applications 目录不可写时会出现系统
管理员授权；从只读 DMG 运行时请先拖到 Applications。细节见 [应用内更新](app-updates.md)。

在配有 Xcode、Flutter、Python 3.11+ 和 Homebrew libusb 的 Mac 上本地构建：

```bash
brew install libusb openssl@3 rust
export DYLD_FALLBACK_LIBRARY_PATH="$(brew --prefix libusb)/lib:/usr/local/lib:/usr/lib"
export OPENSSL_DIR="$(brew --prefix openssl@3)"
export OPENSSL_STATIC=1
export PIP_NO_CACHE_DIR=true
python3 tool/build.py --target macos --mode release --version 1.2.3+4
```

构建脚本在临时源码中编译，版本覆盖只影响该副本；CPU 架构跟随当前 Mac。
脚本验证原始 app、ZIP 解压后的 app 和只读 DMG 内的 app，包括签名、版本、架构、动态库依赖及离线后端 RPC。
包内包含 `Contents/Helpers/take_a_look_updater` 与签名资源 `Contents/Resources/UPDATE-MANIFEST.json`，
构建时会验证更新程序的架构和自检。Mac CI 还会运行真实 `.app` 的自动更新生命周期测试。
成功后自动删除临时文件，失败时保留路径用于诊断；`--keep-build` 可保留成功构建目录。
