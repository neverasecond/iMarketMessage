# iMarketMessage（iMM）v0.1.0-alpha 发布清单

这份清单用于本地预发布和 GitHub Release 准备。发布者必须逐项确认；本仓库不会创建仓库、打 tag、推送、签名、提交公证或发布外部资产。

## 发布身份

- [ ] 公开仓库名确认是 `iMarketMessage`。
- [ ] 面向用户的 macOS 应用名确认是 `iMM`；`MarketMessage` 兼容目标与用户可见名称的差异已在发布说明中解释。
- [ ] 版本号和 tag 确认为 `v0.1.0-alpha`，并与 [`CHANGELOG.md`](CHANGELOG.md)、app bundle 和归档文件名一致。
- [ ] 发布说明包含“本地优先的 macOS 行情提醒工具，不构成投资建议”、数据延迟/限流、outbox/gateway 边界和当前 provider 限制。

## 代码、构建与测试

- [ ] 工作树和待发布 diff 已由发布者检查；没有不相关文件、`.build`、`*.app`、临时日志或缓存。
- [ ] 使用完整 Xcode（不是仅 CommandLineTools），记录 `xcode-select -p`、`xcodebuild -version` 和 `swift --version` 到私有发布记录，不上传个人路径或账户信息。
- [ ] 运行并通过：

  ```sh
  swift build --scratch-path /tmp/imarketmessage-release-build
  swift test --scratch-path /tmp/imarketmessage-release-test
  ```

- [ ] 测试输出确认没有联网、真实 iMessage、真实 Application Support 或 secret 写入。
- [ ] 如进行了 CLI smoke test，已说明它访问 Cboe VIX 或其他外部服务，并确认服务条款、速率限制和结果日期。
- [ ] 验证失败时停止发布；不要把系统运行时库、临时补丁或本机路径提交进仓库。

## 应用包装与用户体验

- [ ] 实际 `.app` bundle 已由发布者准备，Info.plist、bundle identifier、版本、架构、图标和嵌套代码经过检查；未把裸 SwiftPM 可执行文件直接冒充正式 app。
- [ ] 首次启动、规则增删改、Keychain key 保存/删除、outbox 权限和错误状态在干净 Mac 上验证。
- [ ] LaunchAgent 仍是模板，不会随安装自动启用；安装、观察、卸载步骤由用户另行执行。
- [ ] 如果发布页或文档需要截图，截图由用户在脱敏环境中提供；当前仓库没有截图，不生成或伪造占位截图。

## Developer ID 签名与公证（用户本人操作）

- [ ] 参照 [`docs/APPLE_SIGNING.md`](docs/APPLE_SIGNING.md)，由 Account Holder/授权发布者在本人 Mac 上创建或确认 Developer ID Application 证书。
- [ ] CSR、私钥、`.cer`、`.p12`、provisioning profile、App Store Connect 凭据和 `notarytool` Keychain profile 均未进入 Git、CI 日志、issue、PR 或发布附件。
- [ ] 对嵌套代码由内到外签名，使用安全时间戳和 Hardened Runtime；未把 `com.apple.security.get-task-allow=true` 带入发布物；没有使用 `codesign --deep` 代替签名顺序。
- [ ] `codesign --verify --deep --strict --verbose=2` 和 `spctl --assess` 在本机通过。
- [ ] 使用 `xcrun notarytool submit ... --wait` 返回 `Accepted`；拒绝时已停止发布并阅读 Apple 日志。
- [ ] 已对最终 app 执行 `xcrun stapler staple`、`xcrun stapler validate`，重新打包后再次验证；未把未公证版本上传给用户。
- [ ] 提交 ID、证书过期日期、私有日志和签名身份只保存在受控发布记录中，不写入公开说明。

## 归档与 GitHub Release

- [ ] 归档只包含必要的 `.app`/安装材料、许可证和发布说明；没有 `.build`、CSR、私钥、Keychain 导出、outbox、真实规则或测试日志。
- [ ] 为每个公开附件计算 SHA-256，并把校验和与附件一一对应；校验和记录中没有个人路径。
- [ ] 用户本人确认 GitHub Actions 的 CI 已通过；workflow 权限保持最小读权限，不把签名或公证 secrets 加到本 alpha。
- [ ] 用户本人创建 `v0.1.0-alpha` tag 和 GitHub Release，上传经签名、公证、staple 和干净 Mac 验证的最终附件。
- [ ] 发布说明链接到 [`LIMITATIONS.md`](LIMITATIONS.md)、[`PRIVACY.md`](PRIVACY.md)、[`SECURITY.md`](SECURITY.md) 和 [`NOTICE`](NOTICE)。

## 发布后

- [ ] 在另一台干净 Mac 下载公开附件，验证 Gatekeeper、首次启动、卸载和 outbox/gateway 边界。
- [ ] 检查 Release 页面没有泄露账户、Team ID、证书指纹、个人路径、notary 日志或真实消息。
- [ ] 逐个确认并删除本次创建的 `/tmp/imarketmessage-*` scratch、归档副本、notary 日志和不再需要的截图；不要对包含其他用途文件的目录使用未经确认的通配符；保留正式发布附件及必要的私有审计记录。
- [ ] 若发现证书、私钥或公证凭据泄露，立即停止发布并由证书持有人按 Apple 流程撤销/轮换；不要只删除 Git 文件后继续发布。
