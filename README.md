# iMarketMessage（iMM）

iMarketMessage（面向用户的 macOS 应用名：iMM）是一个面向 macOS 14+ 的原生 Swift/SwiftUI 开源 MVP：按自定义证券代码、数据源、指标和阈值评估行情条件，在满足规则时将短消息写入本机安全出站队列，供用户另行授权的 iMessage gateway 发送。当前源码 alpha 版本线为 `v0.1.0-alpha`。

Swift Package 同时保留 `MarketMessage` 兼容识别名；面向用户的可执行目标优先使用 `iMM`，这不代表另一个服务或账号。最终可分发 `.app` 的包装、签名和公证按发布者的实际方案确认，见 [开发者指南](DEVELOPMENT.md)、[限制说明](LIMITATIONS.md) 和 [发布清单](RELEASE_CHECKLIST.md)。

它不会读取 Messages 数据库，不保存电话号码或 chat ID，不安装 LaunchAgent，不自动发送真实消息，也不会调用 Codex/OpenAI。当前项目只负责本地规则和 outbox；gateway、消息路由和联系人权限由用户单独审查并授权。

以下截图是 iMM 的只读演示界面，不读取真实行情、不写入 outbox：

![iMM 只读演示：VIX 高波动示例规则与 Alpha Vantage API key 设置界面](docs/assets/imm-demo-hero.png)

## 快速开始

要求：macOS 14+、完整 Xcode（含 Swift 6 和 Swift Testing 运行时）。仅有精简 CommandLineTools 可能缺少 `lib_TestingInterop.dylib`；请先阅读 [DEVELOPMENT.md](DEVELOPMENT.md)。

```sh
git clone https://github.com/neverasecond/iMarketMessage.git
cd iMarketMessage
swift build --scratch-path /tmp/imarketmessage-build
swift test --scratch-path /tmp/imarketmessage-test
swift run --scratch-path /tmp/imarketmessage-cli market-message-cli --config Config/example-rules.json --outbox /tmp/imarketmessage-outbox --state /tmp/imarketmessage-state.json
# The SwiftUI app stays open until you press Ctrl-C.
swift run --scratch-path /tmp/imarketmessage-app iMM
```

CLI 会输出结构化 JSON 健康状态。默认使用 Application Support 下的 `rules.json`、`Outbox/` 和 `runtime-state.json`；`--config`、`--outbox`、`--state` 可覆盖。上面的 CLI 示例会访问 Cboe VIX 日线；测试完全不联网。临时 scratch 目录不属于仓库，完成后可删除。

测试使用 Swift Testing；完整 Xcode toolchain 会提供测试运行时。精简 CommandLineTools 若报告缺少 `lib_TestingInterop.dylib`，请在完整 Xcode 下运行，不要把系统运行时库加入仓库。

UI 可以浏览、添加、编辑、删除、启用/禁用规则，并选择 provider、指标、比较符、阈值、冷却交易日和“仅首次进入区域”。规则保存到 `~/Library/Application Support/MarketMessage/rules.json`，写入采用原子替换和 `0600` 权限。

## 规则与数据源

- 条件支持 `close` 和 `dailyPercentChange`，比较符 `>=`、`<=`、`>`、`<`。
- 一个规则的条件以 AND 组合；支持冷却交易日、进入区域才触发、启用/禁用。
- `Cboe VIX（日线）`无需 API key，读取 Cboe 公布的 VIX 历史 CSV；请求有超时、HTTP 状态检查、America/New_York 日期解析和过期拒绝。
- `Alpha Vantage（日线）`为 BYO API key 适配器。key 通过抽象的 `APIKeyStore` 取得；macOS 使用 Keychain 实现（`KeychainAPIKeyStore`），测试使用内存替身。key 不会写入规则 JSON、日志或仓库。
- Yahoo/yfinance 仅作为可选 Community provider 方向，不是商业默认，也没有打包非官方抓取代码。使用任何公开 API 前，请自行确认服务条款、许可和速率限制。

市场数据可能延迟、缺失或修订；“过期”判断只是安全闸门，不是交易所日历。市场数据许可和税务/合规责任由使用者承担。iMM 不是投资建议。完整的首版限制见 [LIMITATIONS.md](LIMITATIONS.md)。

## iMessage gateway 边界

`GatewayOutboxSink` 向用户指定的本地目录写入一个 JSON 文件（原子写、文件 `0600`、目录 `0700`）。文件 ID 由规则 UUID 和交易日期确定，同一事件重复运行会覆盖同一文件而不会产生一组随机文件：

```json
{"id":"...","source":"market-message","text":"..."}
```

只允许 `source`、`id`、`text` 三个字段，消息正文默认限制 4,000 UTF-8 字节。真正发送需要一个单独审查、单独授权的本机 gateway；本 MVP 不安装或修改现有 gateway，也不读取联系人和 Messages 数据库。队列消费者协议和 paired-self 限制见 [docs/GATEWAY_PROTOCOL.md](docs/GATEWAY_PROTOCOL.md)，现有个人 gateway 需要另行适配，不声称开箱即发。

当前仓库提供的 gateway 命令只有只读预览。准备好权限为 `0700` 的已有 outbox 目录和首次配对生成的 `paired-self.json` 后，可运行：

```sh
swift run --scratch-path /tmp/imarketmessage-gateway iMM-gateway \
  --dry-run \
  --outbox /tmp/imarketmessage-outbox \
  --pairing /tmp/imarketmessage-paired-self.json \
  --ack /tmp/imarketmessage-gateway-acks.json
```

`--dry-run` 只读取并校验现有文件，绝不发送、创建目录、改权限、写 ACK、移动或删除 outbox 文件；不带 `--dry-run` 会直接拒绝运行。当前源码不包含真实 sender、配对 UI/命令或 LaunchAgent 安装动作，因此没有可用的真实 iMessage 发送路径。

## 后台运行

`Config/com.marketmessage.monitor.plist.example` 是 LaunchAgent 模板。它不包含用户名、token 或绝对个人路径，必须由用户复制后填写路径并自行安装。模板只示范调用 CLI，不会在构建或测试时安装服务。

## 隐私与安全

没有遥测、广告、联系人同步或云端账户。规则和运行状态只写入本机 Application Support；API key 仅进入 Keychain 接口。详见 [PRIVACY.md](PRIVACY.md)、[SECURITY.md](SECURITY.md) 和 [DEVELOPMENT.md](DEVELOPMENT.md)。macOS 的网络、Keychain、文件和自动化权限可能带来风险，请按最小权限审查。

## English summary

iMarketMessage (iMM) is a native macOS 14+ SwiftUI/Swift Package Manager MVP for user-defined market rules. The current source alpha line is `v0.1.0-alpha`; it supports Cboe VIX daily data, an Alpha Vantage BYO-key adapter, AND conditions, entry-only alerts, trading-day cooldowns, atomic `0600` rule storage, and a local JSON outbox for an independently authorized iMessage gateway. It has no telemetry, does not read Messages, and never stores phone numbers, chat IDs, API keys in JSON, or investment advice.

## 开源许可

源代码按 [MPL-2.0](LICENSE) 发布；第三方和数据源说明见 [NOTICE](NOTICE)。
