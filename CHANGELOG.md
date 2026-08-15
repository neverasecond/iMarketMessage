# Changelog

## [0.2.0-beta] - Unreleased

- 增加标准本地 `.app` bundle 构建脚本，输出 ad-hoc 签名的 `iMM.app` 与 ZIP；不冒充 Developer ID 签名或 Apple 公证。
- 增加用户主动授权的 macOS 本地通知，可与原有 JSON outbox 同时接收触发事件。
- 增加基于 `SMAppService` 的后台监控注册、停用和状态展示；LaunchAgent 每 15 分钟运行内置 CLI。
- CI 增加完整 Xcode 下的本地 App bundle、嵌入 helper、plist 和签名结构验证。
- paired-self 真实 iMessage sender、重置确认和干净 Mac 权限验证仍是 beta 发布前阻塞项。

## [0.1.0-alpha] - 2026-08-15

首个公开 alpha，产品定位为本地优先的 macOS 行情提醒工具（iMM），不构成投资建议。

- 支持按证券代码、provider、指标、比较符和阈值定义 AND 规则。
- 支持进入区域触发、交易日冷却、启用/禁用和运行健康状态。
- 内置 Cboe VIX 日线 provider，以及通过 macOS Keychain 保存 BYO API key 的 Alpha Vantage 日线 provider。
- 通过本地、原子写入的 JSON outbox 与独立授权 gateway 对接；本项目不读取 Messages 数据库、不保存电话号码或 chat ID，也不直接发送 iMessage。
- 增加完整 Xcode 下的 macOS GitHub Actions build/test、开发者运行指南、限制说明、发布清单、Issue/PR 模板和 Developer ID 签名/公证指南。

已知限制详见 [`LIMITATIONS.md`](LIMITATIONS.md)。签名、公证和直接分发仍需由拥有相应 Apple 账户和私钥的发布者本人完成，见 [`docs/APPLE_SIGNING.md`](docs/APPLE_SIGNING.md)。
