import SwiftUI
import MarketMessageCore
import ServiceManagement
import UserNotifications

private enum NotificationAuthorizationState: Sendable {
    case authorized
    case provisional
    case ephemeral
    case denied
    case notDetermined
    case unknown
}

/// Keep the user-facing labels for both Service Management entries in one
/// place.  The gateway and monitor have different jobs, but the four
/// Service Management states have the same semantics for each of them.
enum AppServiceStatusKind: Equatable, Sendable {
    case enabled
    case requiresApproval
    case notRegistered
    case notFound
    case unknown
}

enum AppServiceStatusText {
    static func kind(for status: SMAppService.Status) -> AppServiceStatusKind {
        switch status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .notFound
        @unknown default: return .unknown
        }
    }

    static func gateway(for kind: AppServiceStatusKind) -> String {
        switch kind {
        case .enabled: return "已启用（每 30 秒处理 outbox）"
        case .requiresApproval: return "等待在“系统设置 → 登录项”中批准"
        case .notRegistered: return "未注册"
        case .notFound: return "尚未注册；点击“启用 iMessage companion”"
        case .unknown: return "未知状态"
        }
    }
}

/// Keep the non-Sendable UNNotificationSettings value on the notification
/// API's side of the async boundary.  The main-actor view model receives only
/// this small Sendable state.
private func readNotificationAuthorizationState() async -> NotificationAuthorizationState {
    await withCheckedContinuation { continuation in
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let state: NotificationAuthorizationState
            switch settings.authorizationStatus {
            case .authorized: state = .authorized
            case .provisional: state = .provisional
            case .ephemeral: state = .ephemeral
            case .denied: state = .denied
            case .notDetermined: state = .notDetermined
            @unknown default: state = .unknown
            }
            continuation.resume(returning: state)
        }
    }
}

@main
struct MarketMessageApp: App {
    @StateObject private var model: RuleViewModel

    init() {
        _model = StateObject(wrappedValue: RuleViewModel(demoMode: CommandLine.arguments.contains("--demo-screenshot")))
    }

    var body: some Scene {
        WindowGroup("iMM") {
            RuleListView(model: model)
                .frame(minWidth: 820, minHeight: 520)
        }
    }
}

@MainActor
final class RuleViewModel: ObservableObject {
    @Published var rules: [MarketRule] = []
    @Published var selectedID: UUID?
    @Published var persistenceStatus = "尚未保存"
    @Published var health: MonitorHealth?
    @Published var isChecking = false
    @Published var apiKeyInput = ""
    @Published var apiKeyStatus = "未检查"
    @Published var notificationStatus = "未检查"
    @Published var backgroundStatus = "未检查"
    @Published var gatewayStatus = "未检查"
    @Published var backgroundLastRun = "尚无后台运行记录"
    @Published var localNotificationsEnabled = false
    @Published var pairingTargetInput = ""
    @Published var pairingStatus = "未检查"
    @Published var pairingSendStatus = "尚未发送"
    @Published var isPairingSendInProgress = false

    let demoMode: Bool
    private let store: JSONRuleStore?
    private let stateURL: URL?
    private let outboxURL: URL?
    private let pairingURL: URL?
    private let persistenceError: String?
    private let keyStore: KeychainAPIKeyStore?
    private var notificationAuthorized = false
    private static let localNotificationsPreferenceKey = "localNotificationsEnabled"
    private static let monitorPlistName = "com.imarketmessage.monitor.plist"
    private static let gatewayPlistName = "com.imarketmessage.gateway.plist"
    private static let pairingFileName = "paired-self.json"

    init(demoMode: Bool = false) {
        self.demoMode = demoMode
        self.keyStore = demoMode ? nil : KeychainAPIKeyStore()
        if demoMode {
            let condition = RuleCondition(symbol: "VIX", provider: "cboe-vix", metric: .close, comparison: .greaterThanOrEqual, threshold: 25)
            let demoRule = MarketRule(name: "VIX 高波动（示例）", conditions: [condition], cooldownTradingDays: 5)
            self.store = nil
            self.stateURL = nil
            self.outboxURL = nil
            self.pairingURL = nil
            self.persistenceError = "演示模式：仅使用内存示例，不读取或写入本机数据。"
            self.rules = [demoRule]
            self.selectedID = demoRule.id
            self.persistenceStatus = "演示模式：只读 · 仅内存"
            self.apiKeyStatus = "演示模式：不读取 Keychain"
            self.notificationStatus = "演示模式：不请求通知权限"
            self.backgroundStatus = "演示模式：不注册后台服务"
            self.gatewayStatus = "演示模式：不注册 gateway companion"
            self.backgroundLastRun = "演示模式：无后台记录"
            self.pairingStatus = "演示模式：不读取配对状态"
            return
        }
        if let support = try? JSONRuleStore.applicationSupportDirectory() {
            self.store = JSONRuleStore(fileURL: support.appendingPathComponent("rules.json"))
            self.stateURL = support.appendingPathComponent("runtime-state.json")
            self.outboxURL = support.appendingPathComponent("Outbox", isDirectory: true)
            self.pairingURL = support.appendingPathComponent(Self.pairingFileName)
            self.persistenceError = nil
        } else {
            self.store = nil
            self.stateURL = nil
            self.outboxURL = nil
            self.pairingURL = nil
            self.persistenceError = "无法定位 Application Support/MarketMessage，规则不会被写入临时目录。"
        }
        if let store {
            do {
                rules = try store.load().rules
                persistenceStatus = "已加载 " + String(rules.count) + " 条规则"
            } catch {
                persistenceStatus = "加载失败：\(error.localizedDescription)"
            }
        } else {
            persistenceStatus = persistenceError ?? "不可持久化"
        }
        refreshAPIKeyStatus()
        refreshPairingStatus()
        localNotificationsEnabled = UserDefaults.standard.bool(forKey: Self.localNotificationsPreferenceKey)
        refreshBackgroundStatus()
        refreshGatewayStatus()
        Task { await refreshNotificationStatus() }
    }

    func addRule() {
        guard !demoMode else { return }
        let condition = RuleCondition(symbol: "VIX", provider: "cboe-vix", metric: .close, comparison: .greaterThanOrEqual, threshold: 25)
        let rule = MarketRule(name: "VIX 高波动", conditions: [condition], cooldownTradingDays: 5)
        rules.append(rule)
        selectedID = rule.id
        persist()
    }

    func delete(at offsets: IndexSet) {
        guard !demoMode else { return }
        let deletedIDs = Set(offsets.compactMap { index in
            rules.indices.contains(index) ? rules[index].id : nil
        })
        rules.remove(atOffsets: offsets)
        if let selectedID, deletedIDs.contains(selectedID) {
            self.selectedID = rules.first?.id
        }
        persist()
    }

    @discardableResult
    func persist() -> Bool {
        guard !demoMode else {
            persistenceStatus = "演示模式：只读 · 不保存"
            return false
        }
        guard let store else {
            persistenceStatus = persistenceError ?? "不可持久化"
            return false
        }
        do {
            try store.save(RuleSet(rules: rules))
            persistenceStatus = "规则已保存"
            return true
        } catch {
            persistenceStatus = "保存失败：\(error.localizedDescription)"
            return false
        }
    }

    func runOnce() async {
        if demoMode {
            health = MonitorHealth(status: .ok, checkedAt: Date(), evaluatedRules: rules.count, triggeredRules: 0, message: "演示模式：未联网、未写出站队列")
            return
        }
        guard let store, let stateURL, let outboxURL, let keyStore else {
            health = MonitorHealth(status: .configurationError, checkedAt: Date(), evaluatedRules: 0, triggeredRules: 0, message: persistenceError ?? "不可持久化")
            return
        }
        isChecking = true
        defer { isChecking = false }
        guard persist() else {
            health = MonitorHealth(status: .configurationError, checkedAt: Date(), evaluatedRules: 0, triggeredRules: 0, message: persistenceStatus)
            return
        }
        var sinks: [any NotificationSink] = [GatewayOutboxSink(directoryURL: outboxURL)]
        if localNotificationsEnabled && notificationAuthorized {
            sinks.append(LocalUserNotificationSink())
        }
        let service = MonitoringService(
            ruleStore: store,
            providers: [
                "cboe-vix": CboeVIXProvider(),
                "alpha-vantage": AlphaVantageProvider(keyStore: keyStore)
            ],
            sink: CompositeNotificationSink(sinks: sinks),
            stateURL: stateURL
        )
        health = await service.runOnce()
    }

    func refreshAPIKeyStatus() {
        guard !demoMode, let keyStore else { return }
        do {
            apiKeyStatus = (try keyStore.readKey(for: "alpha-vantage")) == nil ? "未配置" : "已配置（不会回显）"
        } catch {
            apiKeyStatus = "Keychain 不可用：" + error.localizedDescription
        }
    }

    /// Refresh only a redacted pairing state.  The paired target is never
    /// copied into a status string, log, notification, or view text.
    func refreshPairingStatus() {
        guard !demoMode else { return }
        guard let pairingURL else {
            pairingStatus = "配对状态不可用"
            return
        }
        do {
            pairingStatus = try GatewayPairingStore(fileURL: pairingURL).load() == nil
                ? "未配对"
                : "已配对（目标已隐藏）"
        } catch {
            pairingStatus = "配对状态不可用"
        }
    }

    /// First-run setup is intentionally one-shot.  A second save is rejected
    /// by GatewayPairingStore instead of silently changing the destination.
    func pairSelf() {
        guard !demoMode, let pairingURL else { return }
        let input = pairingTargetInput
        guard let target = try? PairedSelfTarget(rawValue: input) else {
            pairingTargetInput = ""
            pairingStatus = "目标无效（未保存）"
            return
        }
        do {
            try GatewayPairingStore(fileURL: pairingURL).firstSetup(target: target)
            pairingTargetInput = ""
            pairingStatus = "已配对（目标已隐藏）"
        } catch let error as GatewayStorageError where error == .alreadyPaired {
            pairingTargetInput = ""
            pairingStatus = "已配对（目标已隐藏）"
        } catch {
            pairingTargetInput = ""
            pairingStatus = "配对失败（未保存）"
        }
    }

    /// This method is called only from the destructive confirmation action in
    /// the pairing UI.  It does not accept a replacement target or a CLI flag.
    func resetPairingAfterExplicitConfirmation() {
        guard !demoMode, let pairingURL else { return }
        var companionCleanupError: String?
        if Bundle.main.bundleURL.pathExtension == "app" {
            let service = SMAppService.agent(plistName: Self.gatewayPlistName)
            let kind = AppServiceStatusText.kind(for: service.status)
            if kind == .enabled || kind == .requiresApproval {
                do {
                    try service.unregister()
                } catch {
                    // Deleting the paired target still makes a registered
                    // companion fail closed. Surface the cleanup failure so
                    // the user can retry from the companion controls.
                    companionCleanupError = "停用失败：" + error.localizedDescription
                }
            }
        }
        do {
            try GatewayPairingStore(fileURL: pairingURL).reset()
            pairingTargetInput = ""
            pairingStatus = "未配对"
            refreshGatewayStatus()
            if let companionCleanupError {
                gatewayStatus = companionCleanupError
            }
        } catch {
            pairingStatus = "重置失败（配对未改变）"
        }
    }

    /// Consume the existing outbox once through the same paired-self sender
    /// used by the gateway CLI.  No target input is accepted here; the sender
    /// re-reads the private pairing store and reports only a redacted result.
    func sendOnePairedMessage() async {
        guard !demoMode, let outboxURL, let pairingURL else { return }
        isPairingSendInProgress = true
        defer { isPairingSendInProgress = false }
        let result = await GatewayOutboxConsumer(
            outboxURL: outboxURL,
            pairingURL: pairingURL,
            sender: PairedSelfIMessageSender(pairingURL: pairingURL)
        ).processOnce()
        if result.waitingForPairing {
            pairingSendStatus = "未配对；没有发送"
        } else if result.error != nil || result.failedCount > 0 || result.rejectedCount > 0 || result.quarantinedCount > 0 {
            pairingSendStatus = "发送失败；请查看 gateway 状态"
        } else if result.sentCount > 0 {
            pairingSendStatus = "已提交给 Messages \(result.sentCount) 条（请确认送达）"
        } else if result.duplicateCount > 0 {
            pairingSendStatus = "无新消息（重复已跳过）"
        } else {
            pairingSendStatus = "无待发送消息"
        }
    }

    func saveAPIKey() {
        guard !demoMode, let keyStore else { return }
        do {
            try keyStore.saveKey(apiKeyInput, for: "alpha-vantage")
            apiKeyInput = ""
            apiKeyStatus = "已配置（不会回显）"
        } catch {
            apiKeyStatus = "保存失败：" + error.localizedDescription
        }
    }

    func deleteAPIKey() {
        guard !demoMode, let keyStore else { return }
        do {
            try keyStore.deleteKey(for: "alpha-vantage")
            apiKeyInput = ""
            apiKeyStatus = "未配置"
        } catch {
            apiKeyStatus = "删除失败：" + error.localizedDescription
        }
    }

    func setLocalNotificationsEnabled(_ enabled: Bool) {
        guard !demoMode else { return }
        localNotificationsEnabled = enabled && notificationAuthorized
        UserDefaults.standard.set(localNotificationsEnabled, forKey: Self.localNotificationsPreferenceKey)
    }

    func requestNotificationPermission() async {
        guard !demoMode else { return }
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            notificationAuthorized = granted
            notificationStatus = granted ? "已授权" : "未授权；可在系统设置中更改"
            if granted { setLocalNotificationsEnabled(true) }
        } catch {
            notificationAuthorized = false
            notificationStatus = "请求失败：" + error.localizedDescription
        }
    }

    func refreshNotificationStatus() async {
        guard !demoMode else { return }
        let state = await readNotificationAuthorizationState()
        switch state {
        case .authorized, .provisional, .ephemeral:
            notificationAuthorized = true
            notificationStatus = state == .provisional ? "临时授权" : "已授权"
        case .denied:
            notificationAuthorized = false
            notificationStatus = "已拒绝；请在系统设置中更改"
            setLocalNotificationsEnabled(false)
        case .notDetermined:
            notificationAuthorized = false
            notificationStatus = "尚未请求"
        case .unknown:
            notificationAuthorized = false
            notificationStatus = "未知状态"
        }
    }

    func registerBackgroundMonitor() {
        guard !demoMode else { return }
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            backgroundStatus = "请先用本地构建脚本生成并运行 iMM.app"
            return
        }
        do {
            try SMAppService.agent(plistName: Self.monitorPlistName).register()
            refreshBackgroundStatus()
        } catch {
            backgroundStatus = "启用失败：" + error.localizedDescription
        }
    }

    func unregisterBackgroundMonitor() {
        guard !demoMode else { return }
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            backgroundStatus = "当前不是打包后的 iMM.app"
            return
        }
        do {
            try SMAppService.agent(plistName: Self.monitorPlistName).unregister()
            refreshBackgroundStatus()
        } catch {
            backgroundStatus = "停用失败：" + error.localizedDescription
        }
    }

    func refreshBackgroundStatus() {
        guard !demoMode else { return }
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            backgroundStatus = "源码运行模式；后台服务不可注册"
            return
        }
        switch SMAppService.agent(plistName: Self.monitorPlistName).status {
        case .enabled: backgroundStatus = "已启用（每 15 分钟检查）"
        case .requiresApproval: backgroundStatus = "等待在“系统设置 → 登录项”中批准"
        case .notRegistered: backgroundStatus = "未启用"
        case .notFound: backgroundStatus = "尚未注册；点击“启用后台监控”"
        @unknown default: backgroundStatus = "未知状态"
        }
        refreshBackgroundHealth()
    }

    /// Register the bundled iMessage companion only after the user has
    /// completed paired-self setup.  Reading the private pairing state again
    /// here avoids relying on a stale UI value if the file was removed or
    /// changed outside the app.  A missing/invalid pairing always fails
    /// closed and never calls Service Management.
    func registerGatewayCompanion() {
        guard !demoMode else { return }
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            gatewayStatus = "源码运行模式；gateway companion 不可注册"
            return
        }
        guard hasValidPairingForGateway() else {
            gatewayStatus = "未配对；gateway companion 未注册"
            return
        }
        do {
            try SMAppService.agent(plistName: Self.gatewayPlistName).register()
            refreshGatewayStatus()
        } catch {
            gatewayStatus = "注册失败：" + error.localizedDescription
        }
    }

    /// Stopping a companion is always safe and remains available after a
    /// pairing reset, so a previously registered service can be disabled even
    /// when no destination is currently configured.
    func unregisterGatewayCompanion() {
        guard !demoMode else { return }
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            gatewayStatus = "当前不是打包后的 iMM.app"
            return
        }
        do {
            try SMAppService.agent(plistName: Self.gatewayPlistName).unregister()
            refreshGatewayStatus()
        } catch {
            gatewayStatus = "停用失败：" + error.localizedDescription
        }
    }

    func refreshGatewayStatus() {
        guard !demoMode else { return }
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            gatewayStatus = "源码运行模式；gateway 状态不可查询"
            return
        }
        gatewayStatus = AppServiceStatusText.gateway(
            for: AppServiceStatusText.kind(for: SMAppService.agent(plistName: Self.gatewayPlistName).status)
        )
    }

    private func hasValidPairingForGateway() -> Bool {
        guard let pairingURL else { return false }
        do {
            return try GatewayPairingStore(fileURL: pairingURL).load() != nil
        } catch {
            pairingStatus = "配对状态不可用"
            return false
        }
    }

    private func refreshBackgroundHealth() {
        guard let stateURL else { return }
        let healthURL = stateURL.deletingLastPathComponent().appendingPathComponent("background-health.json")
        guard let data = try? Data(contentsOf: healthURL) else {
            backgroundLastRun = "尚无后台运行记录"
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let value = try? decoder.decode(MonitorHealth.self, from: data) else {
            backgroundLastRun = "后台状态文件无法解析"
            return
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        backgroundLastRun = formatter.string(from: value.checkedAt) + " · " + value.status.rawValue + " · 触发 " + String(value.triggeredRules)
    }

    var healthSummary: String {
        guard let health else { return "未运行检查" }
        return health.status.rawValue + " · 规则 " + String(health.evaluatedRules) + " · 触发 " + String(health.triggeredRules) + (health.message.map { " · " + $0 } ?? "")
    }
}

struct RuleListView: View {
    @ObservedObject var model: RuleViewModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedID) {
                ForEach(model.rules) { rule in
                    HStack {
                        Image(systemName: rule.enabled ? "checkmark.circle.fill" : "pause.circle")
                            .foregroundStyle(rule.enabled ? .green : .secondary)
                        VStack(alignment: .leading) {
                            Text(rule.name).lineLimit(1)
                            Text("\(rule.conditions.count) 条条件 · 冷却 \(rule.cooldownTradingDays) 个交易日")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(rule.id)
                }
                .onDelete(perform: model.delete)
            }
            .navigationTitle("规则")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: model.addRule) { Label("添加", systemImage: "plus") }
                        .disabled(model.demoMode)
                }
            }
        } detail: {
            if let selectedID = model.selectedID,
               let index = model.rules.firstIndex(where: { $0.id == selectedID }) {
                RuleEditorView(rule: $model.rules[index], model: model, onSave: { _ = model.persist() })
            } else {
                ContentUnavailableView("选择一条规则", systemImage: "slider.horizontal.3", description: Text("添加或选择规则后编辑行情条件。"))
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Circle().fill(model.health?.status == .ok ? .green : .secondary).frame(width: 8, height: 8)
                Text("运行健康：\(model.healthSummary)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("持久化：\(model.persistenceStatus)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(model.isChecking ? "检查中…" : "运行一次检查") {
                    Task { await model.runOnce() }
                }
                .disabled(model.isChecking)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }
}

struct RuleEditorView: View {
    @Binding var rule: MarketRule
    @ObservedObject var model: RuleViewModel
    var onSave: () -> Void
    @State private var pairingResetConfirmation = false
    @State private var ruleDeleteConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            if model.demoMode {
                HStack(spacing: 8) {
                    Image(systemName: "eye.slash.fill")
                    Text("演示模式 · 只读")
                        .fontWeight(.semibold)
                    Text("内存示例，不读取本机数据、不联网、不写入 outbox")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .font(.caption)
                .padding(.horizontal)
                .padding(.vertical, 7)
                .background(.yellow.opacity(0.18))
            }

            Form {
                Section("Alpha Vantage API key") {
                    SecureField("输入新 key（不会回显）", text: $model.apiKeyInput)
                    HStack {
                        Text(model.apiKeyStatus).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("保存到 Keychain") { model.saveAPIKey() }
                        Button("删除") { model.deleteAPIKey() }
                    }
                    Text("key 只保存到 macOS Keychain，不写入规则 JSON；Cboe VIX 不需要 key。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("规则") {
                    TextField("名称", text: $rule.name)
                    Toggle("启用", isOn: $rule.enabled)
                    Picker("组合逻辑", selection: $rule.logic) {
                        Text("全部满足（AND）").tag(RuleLogic.all)
                    }
                    Stepper("冷却交易日：\(rule.cooldownTradingDays)", value: $rule.cooldownTradingDays, in: 0...90)
                    Toggle("仅在进入区域时触发", isOn: $rule.triggerOnEntryOnly)
                }

                Section("通知与后台") {
                    HStack {
                        Text("本地通知：" + model.notificationStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("请求权限") { Task { await model.requestNotificationPermission() } }
                    }
                    Toggle("规则触发时显示 macOS 通知", isOn: Binding(
                        get: { model.localNotificationsEnabled },
                        set: { model.setLocalNotificationsEnabled($0) }
                    ))
                    Text("后台监控：" + model.backgroundStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("最近后台检查：" + model.backgroundLastRun)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("启用后台监控") { model.registerBackgroundMonitor() }
                        Button("停用") { model.unregisterBackgroundMonitor() }
                        Button("刷新状态") { model.refreshBackgroundStatus() }
                    }
                    Text("后台服务由 macOS Service Management 管理；启用后可能需要在系统设置的登录项中批准。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("iMessage paired-self") {
                    Text("配对状态：" + model.pairingStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SecureField("输入本人 iMessage 目标（不会显示或记录）", text: $model.pairingTargetInput)
                        .textContentType(.emailAddress)
                        .privacySensitive()
                    HStack {
                        Button("首次配对") { model.pairSelf() }
                        Button("重置配对", role: .destructive) {
                            pairingResetConfirmation = true
                        }
                        Button("刷新") { model.refreshPairingStatus() }
                    }
                    HStack {
                        Text("发送状态：" + model.pairingSendStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(model.isPairingSendInProgress ? "发送中…" : "发送一次") {
                            Task { await model.sendOnePairedMessage() }
                        }
                        .disabled(model.isPairingSendInProgress)
                    }
                    Text("只会发送到这一次配对保存的本人目标；outbox 和命令行都不能指定收件人。重置后必须再次确认并输入目标。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("iMessage gateway companion") {
                    Text("后台 companion：" + model.gatewayStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("启用 iMessage companion") { model.registerGatewayCompanion() }
                        Button("停用 companion") { model.unregisterGatewayCompanion() }
                        Button("刷新状态") { model.refreshGatewayStatus() }
                    }
                    Text("只有已完成 paired-self 配对后才能注册；未配对时会拒绝注册。启用后由 macOS Service Management 按约 30 秒检查一次 outbox；Messages 仍需用户单独批准。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("行情条件") {
                    ForEach($rule.conditions) { $condition in
                        ConditionEditor(condition: $condition)
                    }
                    .onDelete { offsets in rule.conditions.remove(atOffsets: offsets) }
                    Button("添加 AND 条件") {
                        rule.conditions.append(RuleCondition(symbol: "VIX", provider: "cboe-vix", metric: .close, comparison: .greaterThanOrEqual, threshold: 25))
                    }
                }

                Section {
                    Button("保存") { onSave() }
                        .keyboardShortcut(.defaultAction)
                }

                Section("危险操作") {
                    Button("删除当前规则", role: .destructive) {
                        ruleDeleteConfirmation = true
                    }
                    .disabled(model.demoMode)
                    Text("删除后会立即保存规则列表；如需保留，请先取消。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .padding()
            .disabled(model.demoMode)
        }
        .navigationTitle(rule.name.isEmpty ? "编辑规则" : rule.name)
        .alert("确认重置 iMessage 配对？", isPresented: $pairingResetConfirmation) {
            Button("取消", role: .cancel) {}
            Button("确认重置", role: .destructive) {
                model.resetPairingAfterExplicitConfirmation()
            }
        } message: {
            Text("这会删除本机 paired-self 状态；不会发送消息或读取联系人。")
        }
        .alert("确认删除当前规则？", isPresented: $ruleDeleteConfirmation) {
            Button("取消", role: .cancel) {}
            Button("删除规则", role: .destructive) {
                deleteCurrentRule()
            }
        } message: {
            Text("“\(rule.name)”将从本机规则列表中删除并立即保存。")
        }
    }

    private func deleteCurrentRule() {
        guard let index = model.rules.firstIndex(where: { $0.id == rule.id }) else { return }
        model.delete(at: IndexSet(integer: index))
    }
}

struct ConditionEditor: View {
    @Binding var condition: RuleCondition

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("证券代码", text: $condition.symbol)
                    .frame(width: 120)
                Picker("数据源", selection: $condition.provider) {
                    Text("Cboe VIX").tag("cboe-vix")
                    Text("Alpha Vantage").tag("alpha-vantage")
                }
                .frame(width: 180)
            }
            HStack {
                Picker("指标", selection: $condition.metric) {
                    ForEach(MarketMetric.allCases) { metric in
                        Text(metric.displayName).tag(metric)
                    }
                }
                .frame(width: 210)
                Picker("比较", selection: $condition.comparison) {
                    ForEach(ComparisonOperator.allCases) { op in
                        Text(op.rawValue).tag(op)
                    }
                }
                .frame(width: 90)
                TextField("阈值", value: $condition.threshold, format: .number)
                    .frame(width: 110)
            }
        }
        .padding(.vertical, 4)
    }
}
