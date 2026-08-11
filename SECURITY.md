# iMarketMessage（iMM）安全策略 / Security

## 当前边界

- 不读取 Messages 数据库、联系人或聊天 ID。
- 不把 API key、电话号码、聊天 ID 或消息正文写入日志、规则 JSON、Git 或遥测。
- 规则和 outbox 使用原子替换；规则文件为 `0600`，outbox 目录为 `0700`、消息文件为 `0600`。
- 网络客户端检查超时、HTTP 状态、日期/时区和过期数据。
- GitHub Actions 只使用 `contents: read`，当前 CI 不读取签名身份、不上传发布物、不创建 Release。

## 报告问题

请不要在公开 issue 中粘贴 API key、电话号码、消息正文、个人路径或可用于发送消息的 gateway 凭据。使用私密渠道向维护者提供最小可复现信息；在修复前请避免公开利用细节。

这是本地 alpha，不承诺安全自动更新或托管 gateway。用户应审查 macOS 网络、Keychain、文件和自动化权限，并自行验证数据源和 gateway 的供应链。Developer ID 证书、私钥和公证凭据不属于本项目的 issue/PR 或 CI 输入；发布者应按 [docs/APPLE_SIGNING.md](docs/APPLE_SIGNING.md) 管理。
