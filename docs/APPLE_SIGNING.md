# iMM 的 Developer ID 签名与公证

本文是 iMarketMessage（macOS 应用品牌：iMM）`v0.1.0-alpha` 直接分发的操作边界。它只覆盖在 Mac App Store 之外分发 macOS 软件时的 Developer ID Application 签名和 Apple 公证；它不是本仓库的自动发布脚本。

当前仓库是 Swift Package，同时保留 `MarketMessage` 兼容目标并提供面向用户的 `iMM` 目标。发布者必须先把实际可分发的 `.app` bundle、版本号、bundle identifier 和签名顺序确定下来，再把下面的占位路径替换成真实路径。本仓库不写入 Apple Account、Team ID、bundle identifier、证书、私钥、App Store Connect 凭据或个人信息。

## 谁必须亲自完成

以下步骤需要拥有 Apple Developer 账户、私钥或发布权限的用户在自己的 Mac 上完成，不能由普通代码贡献者或本仓库 CI 代办：

- 登录 Apple Developer 账户、确认 Developer Program/Enterprise Program 资格，并由 Account Holder 创建或批准 Developer ID 证书。
- 在本机 Keychain Access 生成 CSR，使私钥留在本人可控的钥匙串中；下载并安装 Apple 返回的证书。
- 保护、备份或撤销签名私钥；决定是否把签名放在受控的专用发布机。绝不要把私钥、`.p12`、CSR、provisioning profile 或钥匙串导出文件提交到 Git。
- 确定真实的应用 bundle identifier、签名身份、分发格式，以及是否需要 Developer ID Installer（只有分发 `.pkg` 时才需要）。
- 使用 Apple 的 `notarytool` 提交软件、接受公证结果、查看日志并 stapling；这会向 Apple 发送发布物。
- 在干净的 Mac 上验证 Gatekeeper、签名、公证票据、首次启动和卸载结果，并决定是否发布到 GitHub Release。

本仓库提供的 GitHub Actions 只做完整 Xcode 下的 `swift build`/`swift test`，不读取签名私钥、不上传公证物，也不创建或推送 GitHub Release。

## 0. 预先检查

在开始前确认本机使用完整 Xcode，而不是仅有 CommandLineTools：

```sh
xcode-select -p
xcodebuild -version
swift --version
```

如果 `xcodebuild` 不可用，先在 Xcode 或 `xcode-select` 中选择完整安装。签名和公证必须使用 Apple 支持的工具链；不要为了绕过错误把系统运行时库复制进仓库。

源码验证和发布打包是两个不同动作。先在不签名的情况下完成 [开发者指南](../DEVELOPMENT.md) 和 [发布清单](../RELEASE_CHECKLIST.md) 的构建/测试，再在隔离的发布目录准备 `.app` 和归档。

## 1. 用 Keychain Access 生成 CSR

Apple 的 CSR 流程会在本机生成密钥对。按 Apple 官方步骤操作：

1. 打开 `/Applications/Utilities/Keychain Access.app`。
2. 选择 **Keychain Access > Certificate Assistant > Request a Certificate from a Certificate Authority**。
3. 在 **User Email Address** 填写发布者自己的地址；在 **Common Name** 使用便于本人识别的密钥名称；**CA Email Address** 留空。
4. 选择 **Saved to disk**，将 `.certSigningRequest` 保存到本人控制的临时目录（例如 `/tmp`），完成后按发布者的保留策略删除或安全归档。

不要把邮箱、姓名、CSR 内容或截图贴进 issue、PR、日志或本仓库。CSR 本身不是证书，但它可能包含个人信息，并且应与相应私钥一起受控。

## 2. 创建并安装 Developer ID Application 证书

在 Apple Developer 网站的 **Certificates, Identifiers & Profiles > Certificates** 中：

1. 选择 **+**，在 **Software** 下选择 **Developer ID**。
2. 选择 **Developer ID Application**（签名 `.app` 或应用内代码），不要误选只用于安装包的 **Developer ID Installer**。
3. 上传刚生成的 `.certSigningRequest`，下载 Apple 返回的 `.cer` 文件。
4. 双击 `.cer`，确认它和对应私钥出现在 Keychain Access 的 **My Certificates** 中。

Apple 的 Developer ID 证书创建要求 Account Holder 角色。若团队使用云托管证书或专用发布机，也必须由团队拥有者按照 Apple 的权限和密钥管理流程配置；不要在本仓库记录团队信息。

在签名之前，仅在本机终端确认身份是否存在：

```sh
security find-identity -p codesigning -v
```

输出中应有以 `Developer ID Application:` 开头的有效身份。不要把整段输出上传到 CI 日志或 issue；其中可能包含团队名称、Team ID 或证书指纹。

## 3. 准备可分发的 app bundle

`swift build -c release` 生成 SwiftPM 可执行文件，但它不自动替代产品所需的 `.app` 包装、Info.plist、bundle identifier、图标、签名设置或发布版本元数据。发布者必须确认实际打包方案；本仓库不凭空创建 bundle identifier，也不把未验证的裸可执行文件称为可发行的 iMM 应用。

在实际 `.app` 路径确定后，先检查其中是否还有嵌套 framework、XPC、插件或其他可执行代码。Apple 要求由内到外签名：先签嵌套代码，再签最外层 app。不要在复杂 bundle 上用 `codesign --deep` 代替明确的签名顺序。

若产品需要 Hardened Runtime，按目标逐一启用；分发签名不得带有 `com.apple.security.get-task-allow` 为 `true` 的调试授权。是否需要其他 entitlement、provisioning profile 或沙盒能力，必须由发布者根据实际 app 能力和 Apple 文档决定。

## 4. 用 Developer ID Application 签名

下面的命令只展示 Apple 官方参数和占位符。请在本人受控的终端中把尖括号占位符替换为真实值；不要把替换后的命令、输出或身份复制回仓库。

```sh
# 先签嵌套代码（若存在），再签最外层 app。
codesign --force --timestamp --options runtime \
  --sign "Developer ID Application: <Team Name> (<Team ID>)" \
  "<path/to/nested-code>"

codesign --force --timestamp --options runtime \
  --sign "Developer ID Application: <Team Name> (<Team ID>)" \
  "<path/to/iMM.app>"
```

注意：

- `--timestamp` 让签名带有安全时间戳；`--options runtime` 启用 Hardened Runtime。
- `codesign` 不要用 `sudo` 运行。Apple 说明签名依赖当前用户的钥匙串和账户信息。
- 如果需要 entitlement，只给实际的主可执行目标传入经过审查的 `--entitlements <file>`；不要给普通库随意加 entitlement。
- 如果存在多个同名身份，可以使用 `security find-identity -p codesigning -v` 输出的指纹来明确选择，但不要把指纹写进仓库。

签名后先做本机验证：

```sh
codesign --verify --deep --strict --verbose=2 "<path/to/iMM.app>"
codesign --display --verbose=4 "<path/to/iMM.app>"
spctl --assess --type execute --verbose=4 "<path/to/iMM.app>"
```

`--deep` 可用于验证整棵 bundle；Apple 不建议用它来签名复杂产品。`spctl` 在尚未公证时可能给出 Gatekeeper 拒绝，这是预期的中间状态，不能代替公证后的验证。

## 5. 打包并提交公证

直接分发通常将签名后的 `.app` 放入 ZIP、DMG 或其他明确的发布容器。打包时使用能保留 bundle 结构的工具，并把输出放在 `/tmp` 或专用发布目录；示例：

```sh
ditto -c -k --keepParent \
  "<path/to/iMM.app>" \
  "/tmp/iMM-v0.1.0-alpha.zip"
```

Apple 已停止接受旧的 `altool` 上传流程；脚本化公证使用 Xcode 提供的 `notarytool`。公证凭据由发布者本人创建并保存在本机 Keychain，不能写入脚本、GitHub issue、PR 或仓库：

```sh
# 仅首次在本人钥匙串创建命名凭据；所有尖括号都是占位符。
xcrun notarytool store-credentials "<notary-profile>" \
  --apple-id "<Apple Account>" \
  --team-id "<Developer Team ID>" \
  --password "<app-specific-password>"

xcrun notarytool submit "/tmp/iMM-v0.1.0-alpha.zip" \
  --keychain-profile "<notary-profile>" \
  --wait
```

`--wait` 返回 `Accepted` 后，保留提交 ID 供发布者本人查看日志；不要把 ID 与路径混入公开日志。若需诊断，先在 `/tmp` 下载并检查日志，发布结束后按清单清理：

```sh
xcrun notarytool log "<submission-id>" \
  --keychain-profile "<notary-profile>" \
  "/tmp/iMM-notary-log.json"
```

公证接受后，把票据 stapling 到最终要分发的 app（或 Apple 文档允许的容器），再重新打包：

```sh
xcrun stapler staple "<path/to/iMM.app>"
xcrun stapler validate "<path/to/iMM.app>"
ditto -c -k --keepParent \
  "<path/to/iMM.app>" \
  "/tmp/iMM-v0.1.0-alpha-notarized.zip"
spctl --assess --type execute --verbose=4 "<path/to/iMM.app>"
```

若返回 `Rejected`，不要上传被拒版本；读取 Apple 返回的日志，修复签名、Hardened Runtime、entitlement 或嵌套代码问题，再重新构建、签名和提交。不要通过关闭安全能力来“绕过”公证。

## 6. 发布前必须由用户确认

- [ ] Developer ID Application 证书和对应私钥在本人控制的 Keychain 中，证书未过期/撤销。
- [ ] 实际 app bundle 的版本、bundle identifier、架构、嵌套代码和签名顺序已记录在私有发布记录中。
- [ ] 已启用 Hardened Runtime；没有把 `get-task-allow` 调试 entitlement 带入发布物。
- [ ] `codesign --verify`、`stapler validate` 和公证后的 `spctl` 均通过。
- [ ] 已在干净 Mac 安装/首次启动，确认 Gatekeeper 显示公证状态；同时确认规则保存、Keychain key 和 outbox 行为符合 [隐私声明](../PRIVACY.md)。
- [ ] 发布物只包含必要文件；没有 CSR、私钥、`.p12`、provisioning profile、notary 凭据、个人路径、真实消息或日志。
- [ ] 如果发布页需要截图，截图必须由用户在真实发布物和脱敏环境中提供；当前仓库没有截图，不能生成或伪造占位截图。
- [ ] 参照 [发布清单](../RELEASE_CHECKLIST.md) 计算发布物校验和、撰写限制说明，并由用户本人创建 tag/release。

## 官方资料

以下链接均为 Apple 官方资料（访问日期：2026-08-11）：

- [Create Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates)
- [Create a certificate signing request](https://developer.apple.com/help/account/certificates/create-a-certificate-signing-request)
- [Creating distribution-signed code for macOS](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/)
- [Hardened Runtime](https://developer.apple.com/documentation/security/hardened-runtime)
- [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [Sharing your team’s signing certificates](https://developer.apple.com/documentation/Xcode/sharing-your-teams-signing-certificates)
