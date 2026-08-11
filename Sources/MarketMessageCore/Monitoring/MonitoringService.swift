import Foundation

public struct MonitorHealth: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case ok
        case noRules
        case configurationError
        case providerError
        case notificationError
        case stateError
    }

    public var status: Status
    public var checkedAt: Date
    /// Number of enabled rules for which every requested snapshot was fetched
    /// and the rule engine actually ran.
    public var evaluatedRules: Int
    public var triggeredRules: Int
    public var message: String?

    public init(status: Status, checkedAt: Date, evaluatedRules: Int, triggeredRules: Int, message: String? = nil) {
        self.status = status
        self.checkedAt = checkedAt
        self.evaluatedRules = evaluatedRules
        self.triggeredRules = triggeredRules
        self.message = message
    }
}

public struct MonitoringService: Sendable {
    public var ruleStore: any RuleStore
    public var providers: [String: any MarketDataProvider]
    public var sink: any NotificationSink
    /// Required so every caller persists entry/cooldown state across processes.
    public let stateURL: URL
    public var engine: RuleEngine

    public init(
        ruleStore: any RuleStore,
        providers: [String: any MarketDataProvider],
        sink: any NotificationSink,
        stateURL: URL,
        engine: RuleEngine = RuleEngine()
    ) {
        self.ruleStore = ruleStore
        self.providers = providers
        self.sink = sink
        self.stateURL = stateURL
        self.engine = engine
    }

    public func runOnce(now: Date = Date()) async -> MonitorHealth {
        var evaluated = 0
        var triggered = 0
        do {
            let ruleSet = try ruleStore.load()
            let enabledRules = ruleSet.rules.filter(\.enabled)
            guard !enabledRules.isEmpty else {
                return MonitorHealth(status: .noRules, checkedAt: now, evaluatedRules: 0, triggeredRules: 0)
            }

            let runtimeStore = RuntimeStateStore(fileURL: stateURL)
            var runtime = try runtimeStore.load()

            // Validate all configuration before making network calls. A missing
            // provider or an empty condition is never treated as a mismatch.
            var requests: [String: (providerID: String, symbol: String)] = [:]
            for rule in enabledRules {
                guard !rule.conditions.isEmpty else {
                    return configurationError("规则“" + rule.name + "”没有条件", now: now, evaluated: evaluated, triggered: triggered)
                }
                for condition in rule.conditions {
                    guard !condition.symbol.isEmpty else {
                        return configurationError("规则“" + rule.name + "”包含空证券代码", now: now, evaluated: evaluated, triggered: triggered)
                    }
                    guard providers[condition.provider] != nil else {
                        return configurationError("未注册行情 provider：" + condition.provider, now: now, evaluated: evaluated, triggered: triggered)
                    }
                    let key = Self.requestKey(provider: condition.provider, symbol: condition.symbol)
                    requests[key] = (condition.provider, condition.symbol)
                }
            }

            // Fetch each provider/symbol at most once for the complete run.
            var snapshots: [String: MarketSnapshot] = [:]
            for key in requests.keys.sorted() {
                guard let request = requests[key], let provider = providers[request.providerID] else {
                    return configurationError("行情请求配置不完整：" + key, now: now, evaluated: evaluated, triggered: triggered)
                }
                let snapshot: MarketSnapshot
                do {
                    snapshot = try await provider.fetch(symbol: request.symbol, now: now)
                } catch let error as DataProviderError {
                    return MonitorHealth(status: .providerError, checkedAt: now, evaluatedRules: evaluated, triggeredRules: triggered, message: error.localizedDescription)
                } catch {
                    return MonitorHealth(status: .providerError, checkedAt: now, evaluatedRules: evaluated, triggeredRules: triggered, message: error.localizedDescription)
                }
                guard snapshot.provider == request.providerID,
                      snapshot.symbol == request.symbol.uppercased() else {
                    return configurationError("provider 返回了错误的证券或数据源：" + key, now: now, evaluated: evaluated, triggered: triggered)
                }
                snapshots[key] = snapshot
            }

            for rule in enabledRules {
                let keys = Set(rule.conditions.map { Self.requestKey(provider: $0.provider, symbol: $0.symbol) })
                let ruleSnapshots = keys.compactMap { snapshots[$0] }
                guard ruleSnapshots.count == keys.count else {
                    return configurationError("规则“" + rule.name + "”缺少行情快照", now: now, evaluated: evaluated, triggered: triggered)
                }
                var state = runtime[rule.id.uuidString] ?? RuleRuntimeState()
                let result = engine.evaluate(rule: rule, snapshots: ruleSnapshots, state: &state)
                runtime[rule.id.uuidString] = state
                evaluated += 1
                if case .triggered = result {
                    triggered += 1
                    let referenceSnapshot = ruleSnapshots.max { $0.tradingDate < $1.tradingDate }
                    let referenceDate = referenceSnapshot?.tradingDate ?? now
                    let text = Self.notificationText(rule: rule, snapshots: ruleSnapshots)
                    let messageID = Self.notificationID(ruleID: rule.id, tradingDate: referenceDate, timeZoneIdentifier: referenceSnapshot?.timeZoneIdentifier ?? "UTC")
                    do {
                        try await sink.send(OutboxMessage(source: "market-message", id: messageID, text: text))
                    } catch {
                        return MonitorHealth(status: .notificationError, checkedAt: now, evaluatedRules: evaluated, triggeredRules: triggered, message: error.localizedDescription)
                    }
                }
            }

            do {
                try runtimeStore.save(runtime)
            } catch let error as RuntimeStateStoreError {
                return MonitorHealth(status: .stateError, checkedAt: now, evaluatedRules: evaluated, triggeredRules: triggered, message: error.localizedDescription)
            } catch {
                return MonitorHealth(status: .stateError, checkedAt: now, evaluatedRules: evaluated, triggeredRules: triggered, message: error.localizedDescription)
            }
            return MonitorHealth(status: .ok, checkedAt: now, evaluatedRules: evaluated, triggeredRules: triggered)
        } catch let error as RuntimeStateStoreError {
            return MonitorHealth(status: .stateError, checkedAt: now, evaluatedRules: evaluated, triggeredRules: triggered, message: error.localizedDescription)
        } catch {
            return MonitorHealth(status: .configurationError, checkedAt: now, evaluatedRules: evaluated, triggeredRules: triggered, message: error.localizedDescription)
        }
    }

    public static func requestKey(provider: String, symbol: String) -> String {
        provider + "|" + symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    public static func notificationID(ruleID: UUID, tradingDate: Date, timeZoneIdentifier: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .gmt
        formatter.dateFormat = "yyyyMMdd"
        return "rule-" + ruleID.uuidString.lowercased() + "-" + (formatter.string(from: tradingDate))
    }

    private static func notificationText(rule: MarketRule, snapshots: [MarketSnapshot]) -> String {
        var lines = ["MarketMessage：" + rule.name]
        let sorted = snapshots.sorted {
            requestKey(provider: $0.provider, symbol: $0.symbol) < requestKey(provider: $1.provider, symbol: $1.symbol)
        }
        for snapshot in sorted {
            let close = snapshot.metrics[.close].map { String(format: "%.4f", $0) } ?? "—"
            let change = snapshot.metrics[.dailyPercentChange].map { String(format: "%.2f%%", $0) } ?? "—"
            lines.append(snapshot.symbol + " close=" + close + " dailyChange=" + change)
        }
        return lines.joined(separator: "\n")
    }

    private func configurationError(_ message: String, now: Date, evaluated: Int, triggered: Int) -> MonitorHealth {
        MonitorHealth(status: .configurationError, checkedAt: now, evaluatedRules: evaluated, triggeredRules: triggered, message: message)
    }
}
