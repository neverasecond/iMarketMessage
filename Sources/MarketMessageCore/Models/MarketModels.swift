import Foundation

public enum MarketMetric: String, Codable, CaseIterable, Identifiable, Sendable {
    case close
    case dailyPercentChange

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .close: return "收盘价 / Close"
        case .dailyPercentChange: return "日涨跌幅 % / Daily %"
        }
    }
}

public enum ComparisonOperator: String, Codable, CaseIterable, Identifiable, Sendable {
    case greaterThanOrEqual = ">="
    case lessThanOrEqual = "<="
    case greaterThan = ">"
    case lessThan = "<"

    public var id: String { rawValue }

    public func matches(_ value: Double, threshold: Double) -> Bool {
        switch self {
        case .greaterThanOrEqual: return value >= threshold
        case .lessThanOrEqual: return value <= threshold
        case .greaterThan: return value > threshold
        case .lessThan: return value < threshold
        }
    }
}

public enum RuleLogic: String, Codable, CaseIterable, Sendable {
    case all
}

public struct RuleCondition: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var symbol: String
    public var provider: String
    public var metric: MarketMetric
    public var comparison: ComparisonOperator
    public var threshold: Double

    public init(
        id: UUID = UUID(),
        symbol: String,
        provider: String,
        metric: MarketMetric,
        comparison: ComparisonOperator,
        threshold: Double
    ) {
        self.id = id
        self.symbol = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        self.provider = provider
        self.metric = metric
        self.comparison = comparison
        self.threshold = threshold
    }
}

public struct MarketRule: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var conditions: [RuleCondition]
    public var logic: RuleLogic
    public var cooldownTradingDays: Int
    public var triggerOnEntryOnly: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        enabled: Bool = true,
        conditions: [RuleCondition],
        logic: RuleLogic = .all,
        cooldownTradingDays: Int = 0,
        triggerOnEntryOnly: Bool = true
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.conditions = conditions
        self.logic = logic
        self.cooldownTradingDays = max(0, cooldownTradingDays)
        self.triggerOnEntryOnly = triggerOnEntryOnly
    }
}

public struct RuleSet: Codable, Equatable, Sendable {
    public var version: Int
    public var rules: [MarketRule]

    public init(version: Int = 1, rules: [MarketRule] = []) {
        self.version = version
        self.rules = rules
    }
}

public struct MarketSnapshot: Codable, Equatable, Sendable {
    public var symbol: String
    public var provider: String
    public var observedAt: Date
    public var tradingDate: Date
    public var timeZoneIdentifier: String
    public var metrics: [MarketMetric: Double]

    public init(
        symbol: String,
        provider: String,
        observedAt: Date,
        tradingDate: Date,
        timeZoneIdentifier: String,
        metrics: [MarketMetric: Double]
    ) {
        self.symbol = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        self.provider = provider
        self.observedAt = observedAt
        self.tradingDate = tradingDate
        self.timeZoneIdentifier = timeZoneIdentifier
        self.metrics = metrics
    }

    public func value(for metric: MarketMetric) -> Double? {
        metrics[metric]
    }
}
