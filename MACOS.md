# macOS 构建与使用

支持 macOS 12 及以上，Intel x64 和 Apple Silicon arm64。

## GitHub Actions

GitHub Actions 左侧的手动入口需要此工作流文件存在于默认分支 `master`。
仅把 macOS 代码推到功能分支不保证该入口出现在列表中。可只把
`.github/workflows/macos.yml` 合入 `master`，保留实现代码在 `macos` 分支。
选择 `macOS x64 and arm64` 工作流，点 Run workflow，`build_ref` 默认填 `macos`；
工作流会从该分支取完整工程。两个任务分别使用
Intel 和 Apple Silicon runner，产物为 `fqapp-macos-x64.zip` 和
`fqapp-macos-arm64.zip`，附 SHA-256 校验文件。

每次构建都会从源码编译 Rust/C 解密核心，随应用打包；检查所有 Mach-O 文件
的架构、动态库路径及媒体解密入口，并验证代码签名。不会引用构建机器的
Homebrew 动态库。macOS 播放库由固定版本的 media_kit macOS 插件提供。

## 本机编译

需要完整 Xcode、Xcode Command Line Tools、Flutter 3.47.9、Rust 1.99.1、
CocoaPods。先运行 `sudo xcodebuild -license accept`（若 Xcode 提示），
并确认 `xcode-select -p` 指向完整 Xcode。

```bash
rustup toolchain install 1.99.1
rustup override set 1.99.1
bash scripts/build_macos.sh x64
# 或
bash scripts/build_macos.sh arm64
# 同时支持两种架构的单一应用
bash scripts/build_macos.sh universal
```

产物在 `dist/`。脚本先编译通用应用，再为单架构产物裁剪所有原生二进制，
保留应用所需的框架与 Rust 核心。重复打包前需移走或删除同名的 `dist/*.app`。
直接 `flutter run -d macos` 也会通过 Xcode 构建阶段编译并嵌入对应架构的 Rust 核心。

当前产物使用本机 ad-hoc 签名，未使用 Developer ID，也未做 Apple 公证。
下载后 macOS 可能要求在系统设置中明确允许打开；正式公开分发应另行配置
Developer ID 签名和 notarization，不要关闭系统安全检查。

## 桌面能力

复用桌面导航、窗口布局、阅读器、media_kit 播放、文件导入导出、备份和 TTS。
番茄登录使用系统 WebKit 窗口，仅读取官方域名登录 Cookie；TXT 导入支持
UTF-8、带 BOM 的 UTF-16 和 GB18030。原生窗口提供阅读/播放防休眠。
Windows SMTC 不在 macOS 初始化；macOS 锁屏媒体按键集成本次未实现。
网络客户端/服务端、用户选择文件和 Keychain 权限均配置在 App Sandbox 中。

Linux 环境只能验证 Dart 逻辑和构建配置；实际 Xcode 编译、双架构运行、
Keychain 持久化、文件授权及媒体播放仍需 macOS CI/真机验证。
