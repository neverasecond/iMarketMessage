# iMarketMessage（iMM）开发者指南

本指南面向维护 `v0.2.0-beta` 开发分支的贡献者。公开仓库名是 **iMarketMessage**，面向用户的 macOS 应用品牌是 **iMM**；Swift Package 保留 `MarketMessage` 兼容识别名，开发和发布优先使用 `iMM`，不代表额外的网络服务或账户。

## 环境

- macOS 14 或更高版本。
- 完整 Xcode（包含 `xcodebuild` 和 Swift Testing 运行时）；仅有 CommandLineTools 可能缺少 `lib_TestingInterop.dylib`。
- Swift 6 工具链。仓库当前没有需要下载的 SwiftPM 依赖。

先确认工具链：

```sh
xcode-select -p
xcodebuild -version
swift --version
```

如果 `xcodebuild` 报告当前目录是 CommandLineTools，请在 Xcode 或 `xcode-select` 中选择完整 Xcode，再继续构建。GitHub Actions 使用相同原则，在 [`.github/workflows/macos-ci.yml`](.github/workflows/macos-ci.yml) 中拒绝只含 CommandLineTools 的 runner。

## 构建与测试

所有 scratch 输出都放在 `/tmp`，不要把 `.build`、日志或运行时数据提交到仓库：

```sh
swift build --scratch-path /tmp/imarketmessage-build
swift test --scratch-path /tmp/imarketmessage-test
```

测试使用 Swift Testing，默认不联网、不发送消息、不写真实的 Application Support。完成本地验证后删除不再需要的临时目录：

```sh
rm -rf -- /tmp/imarketmessage-build /tmp/imarketmessage-test
```

如果目录中混有其他用途的文件，不要使用上面的命令；先确认目标是本次命令创建的临时目录。磁盘空间有限时，优先清理 scratch、日志和预览产物。

## 运行 SwiftUI 应用

```sh
swift run --scratch-path /tmp/imarketmessage-app iMM
```

应用默认把规则保存到 `~/Library/Application Support/MarketMessage/rules.json`，运行状态保存到同目录的 `runtime-state.json`，outbox 位于 `Outbox/`。规则文件使用原子替换和 `0600` 权限，outbox 目录为 `0700`、消息文件为 `0600`。应用不会读取 Messages 数据库、联系人或 chat ID。

应用界面可以添加、编辑、启用/禁用规则，选择 Cboe VIX 或 Alpha Vantage provider，设置 `close`/`dailyPercentChange`、比较符、阈值、冷却交易日和“仅首次进入区域”。Alpha Vantage key 只通过 macOS Keychain 保存，不会写入规则 JSON。

## 构建本机 App、ZIP 与校验和

必须先选择完整 Xcode；脚本会拒绝仅有 CommandLineTools 的环境。构建只写入显式的输出目录，默认是仓库 `dist/`：

```sh
scripts/build-local-app.sh
(cd dist && shasum -a 256 -c iMM-v0.2.0-beta-local.zip.sha256)
```

脚本会构建 `iMM.app`、内嵌 `market-message-cli` 和 `iMM-gateway`，检查两个 LaunchAgent plist，复制 `Packaging/AppIcon-1024.png`（若存在正式 `AppIcon.icns` 则优先使用）到 `Contents/Resources/`，执行嵌套 ad-hoc 签名/验证，最后生成 ZIP 和 ZIP 的 `.sha256` 文件。它不会生成 Developer ID 签名、公证或 staple；当前 PNG 是开发包资源。正式发布前需用完整 Xcode 的 `iconutil` 从经过审查的 iconset 生成并验证 `AppIcon.icns`，并把该验证记录到发布清单。

在本机安装或升级时，脚本只替换一个明确的 `iMM.app`，不会删除 Application Support、outbox 或 Keychain：

```sh
scripts/install-local-app.sh --app dist/iMM.app
scripts/install-local-app.sh --app dist/iMM.app --destination /Applications
```

安装脚本会在替换前尝试停止当前用户的精确服务标签 `gui/$(id -u)/com.imarketmessage.monitor`，但不会替代 App 内的 `SMAppService.unregister()`。如果 App 显示“已启用”或“等待批准”，先在 App 内点击“停用后台监控”，然后再升级。脚本采用 staging/恢复路径，失败时尽量恢复旧 App；不会自动注册新服务。

卸载默认保留用户数据，并且只接受明确的 App 路径：

```sh
scripts/uninstall-local-app.sh --app "$HOME/Applications/iMM.app"
```

只有用户明确选择 `--remove-data` 并确认，脚本才会删除精确的 `~/Library/Application Support/MarketMessage`；它不删除 Keychain 项。卸载前先在 App 内停用后台监控，脚本随后对同一 label 执行 `launchctl bootout`，并在删除前显示准确目标。

## 运行一次 CLI 检查

CLI 输出结构化 JSON 健康状态；它只在规则满足时写入本地 outbox，不负责发送真实 iMessage：

```sh
swift run --scratch-path /tmp/imarketmessage-cli market-message-cli \
  --config Config/example-rules.json \
  --outbox /tmp/imarketmessage-outbox \
  --state /tmp/imarketmessage-state.json
```

此示例会访问 Cboe VIX 日线服务，属于一次真实网络请求；请确认数据源服务条款、网络连通性和速率限制。测试用例不会联网。若使用默认路径，CLI 会落到 Application Support；开发验证优先显式指定 `/tmp` 路径，避免污染个人运行数据。

CLI 的 `--help` 可查看参数：

```sh
swift run --scratch-path /tmp/imarketmessage-cli market-message-cli --help
```

运行后只保留为当前验证所需的 JSON；不要把 outbox、运行状态或 API key 复制到 issue、PR 或仓库。完成后清理本次显式创建的临时路径：

```sh
rm -rf -- /tmp/imarketmessage-cli /tmp/imarketmessage-outbox /tmp/imarketmessage-state.json
```

## 后台运行的边界

`Config/com.marketmessage.monitor.plist.example` 只是旧式 LaunchAgent 模板，包含占位路径，不会在构建或测试时安装服务。v0.2 打包 App 使用 `Contents/Library/LaunchAgents/com.imarketmessage.monitor.plist` 和 `com.imarketmessage.gateway.plist`；主 App 通过 `SMAppService` 管理 monitor，gateway 只有显式 `--send` 才能消费 paired-self outbox。用户必须明确注册/批准所需服务并处理 Apple Events 权限；贡献者不得在代码或 CI 中自动注册、复制或修改用户 LaunchAgent。

真实 Mac 验证仍是发布门槛而非 CI 推断。至少要在 macOS 14+ 的干净账户记录首次启动、通知允许和拒绝、登录项批准、Apple Events 允许/拒绝、重启、睡眠/唤醒、后台停用、升级、卸载和用户数据保留/删除；未完成项必须在 `RELEASE_CHECKLIST.md` 标记为未验证。

真正的 iMessage 发送属于单独审查和授权的 gateway。请先阅读 [`docs/GATEWAY_PROTOCOL.md`](docs/GATEWAY_PROTOCOL.md)，确认 paired-self、幂等 ID、ACK 和本地权限，再决定是否适配；不要从这个仓库推断联系人或自动发送目标。

## 贡献流程

1. 先用最小配置复现问题，并确认是否属于数据服务或用户 gateway 边界。
2. 只修改必要文件；不要提交 `.build`、`*.app`、密钥、证书、个人路径、真实 outbox、日志或截图。开发包中的 `dist/`、ZIP 和 `.sha256` 也不应提交。
3. 运行本指南中的 build/test 命令，并在 PR 中记录 macOS、完整 Xcode 和 Swift 版本。
4. 涉及用户可见行为时更新 README、[`LIMITATIONS.md`](LIMITATIONS.md) 或 [`CHANGELOG.md`](CHANGELOG.md)；新增依赖时同步更新 [`NOTICE`](NOTICE)。
5. 发布相关改动按 [`RELEASE_CHECKLIST.md`](RELEASE_CHECKLIST.md) 和 [`docs/V0.2_UPGRADE.md`](docs/V0.2_UPGRADE.md) 执行；签名和公证只由拥有相应 Apple 账户和私钥的用户完成，步骤见 [`docs/APPLE_SIGNING.md`](docs/APPLE_SIGNING.md)。

## 官方 CI 参考

- [GitHub：Building and testing Swift](https://docs.github.com/en/actions/tutorials/build-and-test-code/swift)
- [GitHub：Workflow syntax for GitHub Actions](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax)
- [GitHub：GitHub-hosted runners reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
