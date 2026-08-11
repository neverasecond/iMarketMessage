import SwiftUI
import MarketMessageCore

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

    let demoMode: Bool
    private let store: JSONRuleStore?
    private let stateURL: URL?
    private let outboxURL: URL?
    private let persistenceError: String?
    private let keyStore: KeychainAPIKeyStore?

    init(demoMode: Bool = false) {
        self.demoMode = demoMode
        self.keyStore = demoMode ? nil : KeychainAPIKeyStore()
        if demoMode {
            let condition = RuleCondition(symbol: "VIX", provider: "cboe-vix", metric: .close, comparison: .greaterThanOrEqual, threshold: 25)
            let demoRule = MarketRule(name: "VIX 高波动（示例）", conditions: [condition], cooldownTradingDays: 5)
            self.store = nil
            self.stateURL = nil
            self.outboxURL = nil
            self.persistenceError = "演示模式：仅使用内存示例，不读取或写入本机数据。"
            self.rules = [demoRule]
            self.selectedID = demoRule.id
            self.persistenceStatus = "演示模式：只读 · 仅内存"
            self.apiKeyStatus = "演示模式：不读取 Keychain"
            return
        }
        if let support = try? JSONRuleStore.applicationSupportDirectory() {
            self.store = JSONRuleStore(fileURL: support.appendingPathComponent("rules.json"))
            self.stateURL = support.appendingPathComponent("runtime-state.json")
            self.outboxURL = support.appendingPathComponent("Outbox", isDirectory: true)
            self.persistenceError = nil
        } else {
            self.store = nil
            self.stateURL = nil
            self.outboxURL = nil
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
        rules.remove(atOffsets: offsets)
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
        let service = MonitoringService(
            ruleStore: store,
            providers: [
                "cboe-vix": CboeVIXProvider(),
                "alpha-vantage": AlphaVantageProvider(keyStore: keyStore)
            ],
            sink: GatewayOutboxSink(directoryURL: outboxURL),
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
            }
            .formStyle(.grouped)
            .padding()
            .disabled(model.demoMode)
        }
        .navigationTitle(rule.name.isEmpty ? "编辑规则" : rule.name)
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
