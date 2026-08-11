# iMarketMessage（iMM）隐私声明 / Privacy

iMarketMessage（iMM）没有遥测、广告、云端账户、联系人导入或第三方分析。规则文件和监控运行状态保存在用户指定的本机 Application Support 路径；outbox 只保存用户明确触发的短消息 JSON。API key 只经过 `APIKeyStore` 接口保存，macOS 实现使用 Keychain，不写入普通 JSON。

网络请求仅发送用户配置的证券代码和数据源所需参数。使用 Alpha Vantage 等公开 API 时，服务商可能按自己的隐私政策记录请求；请阅读其条款。iMessage 的实际发送不属于本项目，必须由用户另行授权的 gateway 处理。

删除规则、运行状态和 outbox 文件即可删除本地数据。项目不主动上传、备份或恢复这些文件。Apple Developer 账户、签名证书、私钥和公证凭据由发布者本人在本机管理，不由本项目收集或写入仓库；发布流程见 [docs/APPLE_SIGNING.md](docs/APPLE_SIGNING.md)。
