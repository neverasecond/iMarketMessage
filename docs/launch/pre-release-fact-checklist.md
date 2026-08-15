# 发布前事实核对表

发布负责人在 `[发布日期：YYYY-MM-DD]` 前逐项勾选，并在“证据”栏填入可复核的提交号、CI 运行、文件路径或文档链接。没有证据的项目保持未勾选；不要用计划、截图或占位链接代替运行结果。

## 1. 发布元数据

| 核对项 | 证据 |
|---|---|
| [ ] 项目名统一为 iMarketMessage，App 名统一为 iMM。 | |
| [ ] 版本号与 tag/release 一致：`v0.1.0-alpha` 或 `v0.2.0-beta`。 | |
| [ ] 发布日期、仓库、截图、CI、开发运行说明、协议、候选登记、签名验证和 DMG 链接已由负责人替换，且每个链接指向实际内容。 | |
| [ ] X 文案中的完成时态与发布页事实一致；未把“计划/待核对”误改成“已提供”。 | |
| [ ] 所有公开文案保留“不是投资建议”，没有收益、胜率或交易建议暗示。 | |

## 2. `v0.1.0-alpha` 必核事实

### 构建、测试和开发说明

- [ ] 在支持的 macOS 14+、Swift 6 工具链运行：

  ```sh
  swift build --scratch-path /tmp/imarketmessage-build
  swift test --scratch-path /tmp/imarketmessage-test
  swift run --scratch-path /tmp/imarketmessage-app iMM
  swift run --scratch-path /tmp/imarketmessage-cli market-message-cli --config Config/example-rules.json --outbox /tmp/imarketmessage-outbox --state /tmp/imarketmessage-state.json
  ```

- [ ] CI 构建和测试为绿色，记录提交号和运行链接；测试没有访问真实网络、发送消息或写用户的 Application Support。
- [ ] 若精简 CommandLineTools 缺少 `lib_TestingInterop.dylib`，已改用完整 Xcode 验证，没有把系统运行时库加入仓库。
- [ ] README 的命令、macOS/Swift 前置条件、数据源说明和已知限制与实际运行结果一致。
- [ ] 截图确实来自本版本，包含必要界面而不包含个人路径、账户、联系人、消息正文、密钥或令牌；替代文字已准备。

### alpha 边界

- [ ] 发布包只宣称源码、截图、CI 和开发者运行说明；没有把未生成的签名 App、DMG 或 gateway 写成现成下载物。
- [ ] 已核对：alpha 不安装 LaunchAgent，不安装或修改现有 gateway，不发送真实 iMessage。
- [ ] 已核对：alpha 不读取 Messages 数据库、联系人或 chat ID，不保存电话号码、API key 到规则 JSON、日志或仓库。
- [ ] 已核对：outbox 仅包含 `source`、`id`、`text`；目录 `0700`、文件 `0600`，正文上限为 4,000 个 UTF-8 字节；重复 `id` 不生成随机事件组。
- [ ] 已核对：数据可能延迟、缺失或修订；过期拒绝不是交易所日历，也不是投资建议。

## 3. `v0.2.0-beta` 必核事实

当前基础状态：仓库已包含 paired-self 真实 sender、App 内首次配对/手动发送，以及 monitor/gateway 两个 `SMAppService` 入口；签名 App、DMG 和完整生命周期实机证据仍需分别核验。`--dry-run` 是只读预览，不是唯一发送路径。下列项目在实现和证据齐全前不得勾选，也不得在公开文案中写成“已提供”。

仅当本版本实际包含对应组件时勾选；未实现项必须在发布页和 X 文案中写成计划或移出范围。

### paired-self gateway

- [ ] gateway 只接受明确配对的一个本人目的地，并拒绝任意收件人、调用者提供的电话号码/chat ID 和联系人自动发现。
- [ ] 队列严格校验 JSON 的三个字段、UTF-8 长度、`source`、安全 `id`、目录/文件权限；畸形、过大或未知来源文件进入隔离区，不发送。
- [ ] `id` 作为幂等键；gateway 只有在持久化 `sent`、`rejected` 或 `failed` ACK 后才移除/移动队列文件；ACK 不含凭据。
- [ ] 实际发送所需的 Messages/自动化权限由独立 gateway 获得并可撤销；iMM 本身仍不读取 Messages 数据库或联系人。
- [ ] 已用不含个人身份的测试数据验证重复事件、失败重试和重启后的行为，且测试消息只到明确配对的本人；记录 `osascript` process accepted 不等于 delivery receipt，以及错误 target 可能 exit 0 但 Messages 失败。

### 后台安装、签名 App 和 DMG

- [ ] 后台安装由用户明确发起，安装路径、运行用户、权限、状态检查、卸载和失败回滚均有文档；未写入用户名、绝对个人路径、token 或 key。
- [ ] 安装/卸载只影响本版本声明的文件，没有覆盖已有 gateway 或修改未授权的系统服务；两个 `SMAppService` 按 gateway→monitor 停用、monitor→gateway 恢复。
- [ ] App 签名由可复核工具验证；记录签名身份、验证时间和结果，不以文件名或截图代替验证。
- [ ] DMG 内容与预期版本一致；记录校验值、大小和下载链接；挂载后的 App 与签名验证对象一致。
- [ ] 发布页明确标注 beta 限制、已知故障和回滚方式，没有暗示稳定性或投资结果。

## 4. 隐私、安全和公开文案

- [ ] `PRIVACY.md`、`SECURITY.md`、`docs/GATEWAY_PROTOCOL.md` 与实现一致，且没有凭据、电话号码、chat ID、个人路径或真实消息正文。
- [ ] 每一条 X 单条文案可脱离上下文理解；没有 hashtags、emoji、评论/转发/私信等互动诱导；占位符已替换或明确保留为待填。
- [ ] 所有截图、CI 日志、构建输出和发布说明都做了脱敏；没有把本机用户名、API key、Keychain 内容、cookie 或 gateway 凭据复制到交付物。
- [ ] 外部 GitHub/平台发布、签名、上传和排程均有当次明确授权；未因准备文案自动创建 issue、release 或发送消息。

## 5. 本机磁盘收口

- [ ] 只保留发布所需源码、必要文档、最终截图和经确认的构建产物。
- [ ] 删除或确认可安全删除：`/tmp/imarketmessage-build`、`/tmp/imarketmessage-test`、`/tmp/imarketmessage-app`、`/tmp/imarketmessage-cli`、示例 outbox、临时日志、截图原稿、失败安装包和重复副本。
- [ ] 检查 `docs/launch/` 之外没有本任务新增的平行发布包、缓存、备份或测试数据；无法确认用途的文件先记录体积和用途，再交由用户决定。
- [ ] 最终检查命令历史和输出没有留下敏感值；未将本次事实或身份信息写入长期记忆。

## 6. Go / No-go

- [ ] 所有“必须”项有证据，未核对项已从公开范围移除或明确标成计划。
- [ ] 发布负责人确认可以公开：`v0.1.0-alpha` 或 `v0.2.0-beta`（勾选一个）：`[ ] alpha`　`[ ] beta`
- [ ] 发布后保留的唯一链接和文件清单已记录；临时数据清理完成。

若任一安全边界、签名状态、链接真实性或磁盘清理无法确认，结论为 No-go，先补证据或缩小发布范围。
