# v0.2.0-beta 限制说明

iMarketMessage（iMM）beta 仍是本地优先的 macOS 行情提醒工具，不构成投资、交易、税务、法律或会计建议。它只提供规则评估、本地通知和本地 outbox，不保证行情准确、及时、完整，也不保证提醒一定送达。

## 行情与规则

- 当前内置 Cboe VIX 日线 provider 和 Alpha Vantage 日线 BYO-key provider；没有承诺其他证券、交易所、资产类别或实时行情支持。
- 数据服务可能延迟、缺失、修订、限流或临时不可用。stale 检查只是安全闸门，不是交易所日历、公司行动或数据许可的完整校验。
- 冷却交易日目前按工作日计数，尚未接入每个交易所的节假日/半日市历；跨市场规则不能把此计数当作精确交易日。
- 数据服务的许可、归属、隐私政策、服务条款和速率限制由使用者自行确认；BYO API key 可能使第三方服务记录请求。
- 多条件只按规则中的 AND 语义评估；缺数据、未知 provider、日期不匹配或状态保存失败会使健康状态异常，不应被当作“没有风险”。

## 消息与后台运行

- 本项目不读取 Messages 数据库、Contacts、电话号码或 chat ID，不自动发现收件人；App 的“发送一次”和 gateway companion 只向一次明确保存的 paired-self 目标发送。
- `GatewayOutboxSink` 只向用户指定的本地目录写入受限 JSON；App UI 和 gateway companion 在用户明确操作/启用并获 Apple Events 授权后，才会通过 AppleScript 发送到 paired-self。它们不接受 recipient 参数，也不调用 GitHub/`gh`、Codex/OpenAI 或用户已有的独立 gateway。
- outbox 文件和 `sent` ACK 都不是送达回执。`osascript` 退出 0 只代表 Messages 接受了发送请求；错误的 paired-self 目标可能让进程成功返回但消息无法送达。正确目标在实机上的送达仍需用户检查 Messages 和目标设备。重复运行使用确定性 ID，消费者必须自行做幂等处理；本仓库不保证消费者在线或兼容。
- 打包 App 的两个 LaunchAgent（monitor 与 gateway companion）分别由用户在 App 内通过 `SMAppService` 明确注册并批准后运行；构建、CI 和安装脚本不会自动启用它们。安装/卸载脚本只能对当前用户的精确 label 执行 `launchctl bootout`，不能代替 App 内 `unregister()`；升级或卸载前必须先在 UI 停用 gateway，再停用 monitor。
- `Config/com.marketmessage.monitor.plist.example` 是旧式占位模板，不能直接当作打包 App 的服务配置。后台频率、日志、崩溃恢复和机器睡眠行为由用户自行管理。

## 安全、隐私与分发

- 没有遥测、广告、云端账户或内置分析；规则、运行状态和 outbox 保存在本机，但其他本机用户、备份、同步目录或恶意进程仍可能影响隐私和完整性。
- Alpha Vantage key 通过 Keychain 接口保存，不写入规则 JSON；Keychain 权限、备份和删除必须由用户在自己的 Mac 上检查。
- 首版不提供自动更新、安全公告推送、托管 gateway、集中审计、跨设备同步或恢复服务。
- CI 在完整 Xcode runner 上验证 `swift build`/`swift test`、bundle/plist、ad-hoc 签名、ZIP 内容和 SHA-256，并可上传短期 Actions artifact；它不执行 Developer ID 签名、公证或发布。`actions/upload-artifact` 只作为 CI 交付通道，不能当作公开 Release 或供应链证明。
- `scripts/build-local-app.sh` 生成的 app/ZIP/`.sha256` 仅供可信源码的本机构建和测试；它没有 Developer ID 身份、Apple 公证、staple 或 Gatekeeper 放行。Release 前必须由发布者本人另行完成签名、公证和干净 Mac 验证，见 [`docs/APPLE_SIGNING.md`](docs/APPLE_SIGNING.md)。
- 当前 bundle 优先纳入经过完整 Xcode `iconutil` 验证的 `Packaging/AppIcon.icns`；没有该正式资源时只纳入 `Packaging/AppIcon-1024.png` 开发图标，CI 的 release-only gate 会停止。图标文件存在本身不等于经过 `iconutil` 验证。
- App UI 的手动发送和 `iMM-gateway --send` 都会启动 `/usr/bin/osascript` 与 Messages 交互；Apple Events 权限、Messages 登录状态、paired-self 文件、发送失败/重试、`osascript` 接受但目标错误的情况和真实送达仍未由静态 CI 证明，必须在真实 Mac 上逐项验证。

## 本地安装与真实 Mac 验证

- 安装/升级脚本只替换明确的 `iMM.app`，默认保留 `~/Library/Application Support/MarketMessage`；卸载只有在用户明确传入 `--remove-data` 并确认时才删除该精确目录。Keychain 中的 API key 不由脚本删除。
- 尚未由本仓库的静态 CI 证明通知授权/拒绝、两个登录项批准、重启、睡眠唤醒、按 gateway→monitor 顺序停用、升级回滚、卸载后两个服务残留或不同架构上的 Gatekeeper 行为；这些必须在真实 macOS 14+ 干净账户按 [`RELEASE_CHECKLIST.md`](RELEASE_CHECKLIST.md) 逐项记录。

## 支持范围

首版只把 macOS 14+、完整 Xcode/Swift 6 工具链和仓库中明确列出的 provider 作为目标环境。其他 macOS 版本、仅 CommandLineTools、第三方打包器、非官方行情抓取器或现有个人 gateway 均需要用户自行验证，不能从项目默认行为推断兼容性。

发现问题时，请使用 issue 模板提供脱敏的最小复现；不要上传 secret、个人路径、真实消息或证书输出。提交新功能前，确认它不会扩大默认权限、隐私收集或消息发送边界。
