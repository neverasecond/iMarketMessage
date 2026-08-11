## 变更说明

<!-- 简述用户可见结果、影响范围和任何迁移步骤。请勿粘贴 secret、个人路径或真实消息。 -->

## 验证

- [ ] `swift build --scratch-path /tmp/imarketmessage-pr-build`
- [ ] `swift test --scratch-path /tmp/imarketmessage-pr-test`
- [ ] 若测试环境只有 CommandLineTools，我已改用完整 Xcode，并记录了结果
- [ ] 我已检查测试、日志和 diff 中没有 API key、证书、电话号码、chat ID、个人路径或消息正文

## 边界与文档

- [ ] 本 PR 不读取 Messages 数据库或联系人，不默认发送真实 iMessage
- [ ] 本 PR 不自动安装 LaunchAgent、不修改外部 gateway、不向外部平台写入数据
- [ ] 若新增依赖，我已在 `NOTICE` 说明其许可证和数据/服务条款边界
- [ ] 若影响用户行为，我已更新 README、`DEVELOPMENT.md`、`LIMITATIONS.md` 或 `CHANGELOG.md`
- [ ] 若是发布相关改动，我已对照 `RELEASE_CHECKLIST.md`

## 额外说明

<!-- 可选：已知限制、兼容性、回滚方式。 -->
