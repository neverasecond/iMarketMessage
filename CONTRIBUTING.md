# iMarketMessage（iMM）贡献指南

欢迎提交小而可审查的改动。请先说明问题和 macOS/Swift 版本，再提交最小补丁。

- `swift build --scratch-path /tmp/imarketmessage-build`
- `swift test --scratch-path /tmp/imarketmessage-test`
- 测试使用 Swift Testing；完整 Xcode/Swift toolchain 提供测试运行时。仅有精简 CommandLineTools 时可能缺少 `lib_TestingInterop.dylib`，应改用完整 Xcode，而不是把任何运行时库提交到仓库。
- 测试不得联网、发送消息、写真实 Application Support 或记录 secret。
- 不要提交 `.build`、密钥、电话号码、chat ID、真实 outbox、截图或日志。
- 数据源适配器必须有超时、HTTP 状态检查、日期/时区和 stale 检查。
- 新增依赖请说明许可证，并更新 `NOTICE`。

提交前请检查 diff 中没有个人路径和 API key。Issue/PR 请使用 `.github` 模板并提供脱敏的最小复现。当前 alpha 不接受自动安装 LaunchAgent、读取 Messages/联系人、修改用户 gateway、直接发送真实消息或部署到外部平台的补丁。

涉及用户可见行为时同步更新 [README.md](README.md)、[LIMITATIONS.md](LIMITATIONS.md) 或 [CHANGELOG.md](CHANGELOG.md)；发布相关改动请对照 [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md)。Developer ID 证书、签名私钥和公证必须由发布者本人管理，步骤见 [docs/APPLE_SIGNING.md](docs/APPLE_SIGNING.md)。
