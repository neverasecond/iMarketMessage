import Foundation

public struct RuleRuntimeState: Codable, Equatable, Sendable {
    public var wasMatching: Bool
    public var lastTriggeredTradingDate: Date?

    public init(wasMatching: Bool = false, lastTriggeredTradingDate: Date? = nil) {
        self.wasMatching = wasMatching
        self.lastTriggeredTradingDate = lastTriggeredTradingDate
    }
}

public enum RuleEvaluation: Equatable, Sendable {
    case disabled
    case noData
    case notMatching
    case coolingDown(remainingTradingDays: Int)
    case alreadyInRegion
    case triggered
}

public struct RuleEngine: Sendable {
    public init() {}

    public func evaluate(
        rule: MarketRule,
        snapshot: MarketSnapshot,
        state: inout RuleRuntimeState
    ) -> RuleEvaluation {
        evaluate(rule: rule, snapshots: [snapshot], state: &state)
    }

    /// Evaluates all conditions against the matching symbol/provider snapshot.
    /// This lets an AND rule combine more than one instrument without making
    /// the data provider or notification layer aware of rule semantics.
    public func evaluate(
        rule: MarketRule,
        snapshots: [MarketSnapshot],
        state: inout RuleRuntimeState
    ) -> RuleEvaluation {
        guard rule.enabled else {
            state.wasMatching = false
            return .disabled
        }
        let matching = matches(rule: rule, snapshots: snapshots)
        guard matching else {
            state.wasMatching = false
            return .notMatching
        }

        guard let referenceSnapshot = snapshots.max(by: { $0.tradingDate < $1.tradingDate }) else {
            state.wasMatching = false
            return .noData
        }

        defer { state.wasMatching = true }
        if rule.triggerOnEntryOnly && state.wasMatching {
            return .alreadyInRegion
        }

        if let last = state.lastTriggeredTradingDate,
           rule.cooldownTradingDays > 0 {
            let elapsed = tradingDaysBetween(last, referenceSnapshot.tradingDate, calendar: calendar(for: referenceSnapshot))
            if elapsed <= rule.cooldownTradingDays {
                return .coolingDown(remainingTradingDays: rule.cooldownTradingDays - elapsed + 1)
            }
        }

        state.lastTriggeredTradingDate = referenceSnapshot.tradingDate
        return .triggered
    }

    public func matches(rule: MarketRule, snapshot: MarketSnapshot) -> Bool {
        matches(rule: rule, snapshots: [snapshot])
    }

    public func matches(rule: MarketRule, snapshots: [MarketSnapshot]) -> Bool {
        guard !rule.conditions.isEmpty else { return false }
        let results = rule.conditions.map { condition in
            snapshots.contains { snapshot in
                condition.symbol == snapshot.symbol &&
                condition.provider == snapshot.provider &&
                snapshot.value(for: condition.metric).map {
                    condition.comparison.matches($0, threshold: condition.threshold)
                } ?? false
            }
        }
        switch rule.logic {
        case .all:
            return results.allSatisfy { $0 }
        }
    }

    private func calendar(for snapshot: MarketSnapshot) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: snapshot.timeZoneIdentifier) ?? .gmt
        return calendar
    }

    /// Counts weekdays strictly after `from` through `to`; market-specific holidays
    /// are intentionally left to a future exchange-calendar adapter.
    private func tradingDaysBetween(_ from: Date, _ to: Date, calendar: Calendar) -> Int {
        let start = calendar.startOfDay(for: from)
        let end = calendar.startOfDay(for: to)
        guard end > start else { return 0 }
        var cursor = start
        var count = 0
        while let next = calendar.date(byAdding: .day, value: 1, to: cursor), next <= end {
            let weekday = calendar.component(.weekday, from: next)
            if weekday != 1 && weekday != 7 { count += 1 }
            cursor = next
        }
        return count
    }
}
