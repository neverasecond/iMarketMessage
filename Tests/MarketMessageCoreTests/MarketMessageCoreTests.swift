import Foundation
import Testing
@testable import MarketMessageCore

struct MarketMessageCoreTests {
    @Test func compositeSinkForwardsToEveryEnabledDestination() async throws {
        let first = MockNotificationSink()
        let second = MockNotificationSink()
        let sink = CompositeNotificationSink(sinks: [first, second])
        let message = OutboxMessage(source: "market-message", id: "rule-test-20260815", text: "triggered")

        try await sink.send(message)

        #expect(await first.allMessages() == [message])
        #expect(await second.allMessages() == [message])
    }

    @Test func comparisonOperators() {
        #expect(ComparisonOperator.greaterThanOrEqual.matches(10, threshold: 10))
        #expect(ComparisonOperator.lessThanOrEqual.matches(10, threshold: 10))
        #expect(ComparisonOperator.greaterThan.matches(11, threshold: 10))
        #expect(!ComparisonOperator.greaterThan.matches(10, threshold: 10))
        #expect(ComparisonOperator.lessThan.matches(9, threshold: 10))
        #expect(!ComparisonOperator.lessThan.matches(10, threshold: 10))
    }

    @Test func andRuleRequiresEveryCondition() {
        let rule = MarketRule(
            name: "AND",
            conditions: [
                RuleCondition(symbol: "VIX", provider: "test", metric: .close, comparison: .greaterThanOrEqual, threshold: 20),
                RuleCondition(symbol: "VIX", provider: "test", metric: .dailyPercentChange, comparison: .greaterThan, threshold: 1)
            ]
        )
        let engine = RuleEngine()
        #expect(engine.matches(rule: rule, snapshot: snapshot(close: 25, percent: 2)))
        #expect(!engine.matches(rule: rule, snapshot: snapshot(close: 25, percent: 0.5)))
    }

    @Test func highVolatilityEntryDoesNotRepeat() {
        let rule = MarketRule(
            name: "High volatility",
            conditions: [RuleCondition(symbol: "VIX", provider: "test", metric: .close, comparison: .greaterThanOrEqual, threshold: 25)],
            triggerOnEntryOnly: true
        )
        var state = RuleRuntimeState()
        let engine = RuleEngine()
        #expect(engine.evaluate(rule: rule, snapshot: snapshot(close: 30), state: &state) == .triggered)
        #expect(engine.evaluate(rule: rule, snapshot: snapshot(close: 31, day: 1), state: &state) == .alreadyInRegion)
        #expect(engine.evaluate(rule: rule, snapshot: snapshot(close: 20, day: 2), state: &state) == .notMatching)
        #expect(engine.evaluate(rule: rule, snapshot: snapshot(close: 30, day: 3), state: &state) == .triggered)
    }

    @Test func fiveTradingDayCooldown() {
        let rule = MarketRule(
            name: "Cooldown",
            conditions: [RuleCondition(symbol: "VIX", provider: "test", metric: .close, comparison: .greaterThanOrEqual, threshold: 25)],
            cooldownTradingDays: 5,
            triggerOnEntryOnly: false
        )
        var state = RuleRuntimeState()
        let engine = RuleEngine()
        #expect(engine.evaluate(rule: rule, snapshot: snapshot(close: 30), state: &state) == .triggered)
        #expect(engine.evaluate(rule: rule, snapshot: snapshot(close: 30, day: 1), state: &state) == .coolingDown(remainingTradingDays: 5))
        #expect(engine.evaluate(rule: rule, snapshot: snapshot(close: 30, day: 7), state: &state) == .coolingDown(remainingTradingDays: 1))
        #expect(engine.evaluate(rule: rule, snapshot: snapshot(close: 30, day: 8), state: &state) == .triggered)
    }

    @Test func atomicRuleStorageAndPermissions() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("rules.json")
        let store = JSONRuleStore(fileURL: file)
        let rule = MarketRule(name: "Persist", conditions: [RuleCondition(symbol: "VIX", provider: "test", metric: .close, comparison: .greaterThan, threshold: 1)])
        try store.save(RuleSet(rules: [rule]))
        let loaded = try store.load()
        #expect(loaded.rules == [rule])
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        let temporaryFiles = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(!temporaryFiles.contains { $0.lastPathComponent.hasPrefix(".rules-") })
    }

    @Test func runtimeStateAtomicPermissionsAndCrossRunEntryState() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rules = [MarketRule(name: "Persisted entry", conditions: [RuleCondition(symbol: "VIX", provider: "test", metric: .close, comparison: .greaterThanOrEqual, threshold: 25)], triggerOnEntryOnly: true)]
        let store = JSONRuleStore(fileURL: directory.appendingPathComponent("rules.json"))
        try store.save(RuleSet(rules: rules))
        let provider = CountingProvider(identifier: "test", symbol: "VIX", close: 30)
        let sink = MockNotificationSink()
        let stateURL = directory.appendingPathComponent("runtime-state.json")
        let service = MonitoringService(ruleStore: store, providers: ["test": provider], sink: sink, stateURL: stateURL)
        let now = snapshot(close: 30).observedAt
        let first = await service.runOnce(now: now)
        let second = await service.runOnce(now: now)
        #expect(first.status == .ok)
        #expect(first.triggeredRules == 1)
        #expect(second.status == .ok)
        #expect(second.triggeredRules == 0)
        #expect(await provider.callCount() == 2)
        let stateAttributes = try FileManager.default.attributesOfItem(atPath: stateURL.path)
        #expect((stateAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let stateDirectoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect((stateDirectoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test func unknownProviderIsConfigurationError() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rule = MarketRule(name: "Unknown", conditions: [RuleCondition(symbol: "SPY", provider: "missing", metric: .close, comparison: .greaterThan, threshold: 1)])
        let store = JSONRuleStore(fileURL: directory.appendingPathComponent("rules.json"))
        try store.save(RuleSet(rules: [rule]))
        let stateURL = directory.appendingPathComponent("state.json")
        let health = await MonitoringService(ruleStore: store, providers: [:], sink: MockNotificationSink(), stateURL: stateURL).runOnce()
        #expect(health.status == .configurationError)
        #expect(health.evaluatedRules == 0)
        #expect(health.message?.contains("missing") == true)
    }

    @Test func mismatchedSnapshotIsConfigurationError() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rule = MarketRule(name: "Bad snapshot", conditions: [RuleCondition(symbol: "SPY", provider: "test", metric: .close, comparison: .greaterThan, threshold: 1)])
        let store = JSONRuleStore(fileURL: directory.appendingPathComponent("rules.json"))
        try store.save(RuleSet(rules: [rule]))
        let provider = MismatchedProvider(identifier: "test")
        let stateURL = directory.appendingPathComponent("state.json")
        let health = await MonitoringService(ruleStore: store, providers: ["test": provider], sink: MockNotificationSink(), stateURL: stateURL).runOnce()
        #expect(health.status == .configurationError)
        #expect(health.evaluatedRules == 0)
    }

    @Test func fetchIsCachedAcrossRulesAndEvaluatedRulesCountsRules() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let conditions = { (threshold: Double) in RuleCondition(symbol: "VIX", provider: "test", metric: .close, comparison: .greaterThanOrEqual, threshold: threshold) }
        let rules = [MarketRule(name: "One", conditions: [conditions(10)]), MarketRule(name: "Two", conditions: [conditions(20)])]
        let store = JSONRuleStore(fileURL: directory.appendingPathComponent("rules.json"))
        try store.save(RuleSet(rules: rules))
        let provider = CountingProvider(identifier: "test", symbol: "VIX", close: 30)
        let sink = MockNotificationSink()
        let health = await MonitoringService(ruleStore: store, providers: ["test": provider], sink: sink, stateURL: directory.appendingPathComponent("state.json")).runOnce(now: snapshot(close: 30).observedAt)
        #expect(health.status == .ok)
        #expect(health.evaluatedRules == 2)
        #expect(health.triggeredRules == 2)
        #expect(await provider.callCount() == 1)
    }

    @Test func deterministicOutboxIDAndMultiSnapshotText() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rules = [MarketRule(name: "Two instruments", conditions: [
            RuleCondition(symbol: "AAA", provider: "test", metric: .close, comparison: .greaterThan, threshold: 1),
            RuleCondition(symbol: "BBB", provider: "test", metric: .close, comparison: .greaterThan, threshold: 1)
        ])]
        let store = JSONRuleStore(fileURL: directory.appendingPathComponent("rules.json"))
        try store.save(RuleSet(rules: rules))
        let sink = GatewayOutboxSink(directoryURL: directory.appendingPathComponent("outbox"))
        let providers: [String: any MarketDataProvider] = [
            "test": MultiSnapshotProvider(identifier: "test", values: ["AAA": 2, "BBB": 3])
        ]
        let stateURL = directory.appendingPathComponent("state.json")
        let now = snapshot(close: 2).observedAt
        let service = MonitoringService(ruleStore: store, providers: providers, sink: sink, stateURL: stateURL)
        let first = await service.runOnce(now: now)
        let second = await service.runOnce(now: now)
        #expect(first.triggeredRules == 1)
        #expect(second.triggeredRules == 0)
        let files = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("outbox"), includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        #expect(files.count == 1)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: files[0])) as? [String: String])
        #expect(object["id"]?.hasPrefix("rule-") == true)
        #expect(object["text"]?.contains("AAA") == true)
        #expect(object["text"]?.contains("BBB") == true)
        #expect(object["text"]?.contains("dailyChange") == true)
    }

    @Test func outboxFormatAndPermissions() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sink = GatewayOutboxSink(directoryURL: directory)
        try await sink.send(OutboxMessage(source: "ignored-by-sink", id: "test-1", text: "hello"))
        let file = directory.appendingPathComponent("test-1.json")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: String])
        #expect(Set(object.keys) == Set(["source", "id", "text"]))
        #expect(object["source"] == "market-message")
        #expect(object["id"] == "test-1")
        #expect(object["text"] == "hello")
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test func staleDataRejected() {
        let policy = DataFreshnessPolicy(maximumAge: 60)
        do {
            try policy.validate(observedAt: Date(timeIntervalSince1970: 0), now: Date(timeIntervalSince1970: 120))
            Issue.record("expected stale data error")
        } catch let error as DataProviderError {
            #expect(error == .staleData(Date(timeIntervalSince1970: 0)))
        } catch {
            Issue.record("unexpected error")
        }
    }

    @Test func alphaDateUsesNewYorkCloseAndInformationIsRateLimit() async throws {
        let payload = Data("{\"Time Series (Daily)\": {\"2026-08-07\": {\"4. close\": \"100\"}, \"2026-08-06\": {\"4. close\": \"98\"}}}".utf8)
        let provider = AlphaVantageProvider(client: StaticHTTPClient(data: payload), keyStore: configuredMemoryKeyStore(), freshness: DataFreshnessPolicy(maximumAge: 7 * 86_400))
        let now = try date("2026-08-10 12:00", timeZone: "America/New_York")
        let snapshot = try await provider.fetch(symbol: "SPY", now: now)
        let expected = try date("2026-08-07 16:00", timeZone: "America/New_York")
        #expect(snapshot.observedAt == expected)
        #expect(snapshot.timeZoneIdentifier == "America/New_York")

        let limited = AlphaVantageProvider(client: StaticHTTPClient(data: Data("{\"Information\": \"rate limit\"}".utf8)), keyStore: configuredMemoryKeyStore())
        do {
            _ = try await limited.fetch(symbol: "SPY", now: now)
            Issue.record("expected rate-limit error")
        } catch let error as DataProviderError {
            #expect(error == .rateLimited(provider: "alpha-vantage"))
        }
    }

    @Test func missingAPIKeyDoesNotUseNetwork() async {
        let provider = AlphaVantageProvider(client: NoNetworkHTTPClient(), keyStore: MemoryAPIKeyStore())
        do {
            _ = try await provider.fetch(symbol: "SPY", now: Date())
            Issue.record("expected missing key")
        } catch let error as DataProviderError {
            #expect(error == .missingAPIKey(provider: "alpha-vantage"))
        } catch {
            Issue.record("unexpected error")
        }
    }

    @Test func stateSaveFailureIsHealthError() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rule = MarketRule(name: "State failure", conditions: [RuleCondition(symbol: "VIX", provider: "test", metric: .close, comparison: .greaterThan, threshold: 1)])
        let store = JSONRuleStore(fileURL: directory.appendingPathComponent("rules.json"))
        try store.save(RuleSet(rules: [rule]))
        let badStateURL = URL(fileURLWithPath: "/dev/null/runtime-state.json")
        let health = await MonitoringService(ruleStore: store, providers: ["test": CountingProvider(identifier: "test", symbol: "VIX", close: 2)], sink: MockNotificationSink(), stateURL: badStateURL).runOnce(now: snapshot(close: 2).observedAt)
        #expect(health.status == .stateError)
    }

    private func snapshot(close: Double, percent: Double = 0, day: Int = 0) -> MarketSnapshot {
        let date = Date(timeIntervalSince1970: TimeInterval(day * 86_400))
        return MarketSnapshot(symbol: "VIX", provider: "test", observedAt: date, tradingDate: date, timeZoneIdentifier: "UTC", metrics: [.close: close, .dailyPercentChange: percent])
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MarketMessageTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func configuredMemoryKeyStore() -> MemoryAPIKeyStore {
        let store = MemoryAPIKeyStore()
        try? store.saveKey("test-key", for: "alpha-vantage")
        return store
    }

    private func date(_ value: String, timeZone: String) throws -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: timeZone)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        guard let result = formatter.date(from: value) else { throw NSError(domain: "test", code: 1) }
        return result
    }
}

private actor CountingProvider: MarketDataProvider {
    let identifier: String
    let displayName: String
    let symbol: String
    let close: Double
    private var calls = 0

    init(identifier: String, symbol: String, close: Double) {
        self.identifier = identifier
        self.displayName = identifier
        self.symbol = symbol
        self.close = close
    }

    func fetch(symbol: String, now: Date) async throws -> MarketSnapshot {
        calls += 1
        return MarketSnapshot(symbol: self.symbol, provider: identifier, observedAt: now, tradingDate: now, timeZoneIdentifier: "UTC", metrics: [.close: close, .dailyPercentChange: 1])
    }

    func callCount() -> Int { calls }
}

private struct MultiSnapshotProvider: MarketDataProvider {
    let identifier: String
    let displayName: String
    let values: [String: Double]

    init(identifier: String, values: [String: Double]) {
        self.identifier = identifier
        self.displayName = identifier
        self.values = values
    }

    func fetch(symbol: String, now: Date) async throws -> MarketSnapshot {
        MarketSnapshot(symbol: symbol, provider: identifier, observedAt: now, tradingDate: now, timeZoneIdentifier: "UTC", metrics: [.close: values[symbol] ?? 0, .dailyPercentChange: 1])
    }
}

private struct MismatchedProvider: MarketDataProvider {
    let identifier: String
    let displayName: String

    init(identifier: String) {
        self.identifier = identifier
        self.displayName = identifier
    }

    func fetch(symbol: String, now: Date) async throws -> MarketSnapshot {
        MarketSnapshot(symbol: "OTHER", provider: identifier, observedAt: now, tradingDate: now, timeZoneIdentifier: "UTC", metrics: [.close: 2])
    }
}

private struct StaticHTTPClient: HTTPClient {
    let data: Data

    func get(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private struct NoNetworkHTTPClient: HTTPClient {
    func get(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw DataProviderError.invalidResponse("network disabled in test")
    }
}
