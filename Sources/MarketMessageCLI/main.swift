import Foundation
import MarketMessageCore

@main
struct MarketMessageCLI {
    static func main() async {
        let arguments = CommandLine.arguments.dropFirst()
        if arguments.contains("--help") || arguments.contains("-h") {
            print("Usage: market-message-cli [--config PATH] [--outbox PATH] [--state PATH] [--health PATH] [--local-notification] [--background]")
            print("--local-notification schedules a macOS notification only when the user has already granted permission in iMM.")
            print("--background uses Application Support defaults, enables local notifications, and records background-health.json.")
            return
        }

        do {
            let configURL = value(after: "--config", in: arguments).map(URL.init(fileURLWithPath:))
            let outboxURL = value(after: "--outbox", in: arguments).map(URL.init(fileURLWithPath:))
            let stateURL = value(after: "--state", in: arguments).map(URL.init(fileURLWithPath:))
            let healthURL = value(after: "--health", in: arguments).map(URL.init(fileURLWithPath:))
            let backgroundMode = arguments.contains("--background")
            let needsApplicationSupport = configURL == nil || outboxURL == nil || stateURL == nil || (backgroundMode && healthURL == nil)
            let support = needsApplicationSupport ? try JSONRuleStore.applicationSupportDirectory() : nil
            let config = configURL ?? support!.appendingPathComponent("rules.json")
            let outbox = outboxURL ?? support!.appendingPathComponent("Outbox", isDirectory: true)
            let state = stateURL ?? support!.appendingPathComponent("runtime-state.json")
            let store = JSONRuleStore(fileURL: config)

            let providers: [String: any MarketDataProvider] = [
                "cboe-vix": CboeVIXProvider(),
                "alpha-vantage": AlphaVantageProvider(keyStore: KeychainAPIKeyStore())
            ]
            var sinks: [any NotificationSink] = [GatewayOutboxSink(directoryURL: outbox)]
            if arguments.contains("--local-notification") || backgroundMode {
                sinks.append(LocalUserNotificationSink())
            }
            let service = MonitoringService(
                ruleStore: store,
                providers: providers,
                sink: CompositeNotificationSink(sinks: sinks),
                stateURL: state
            )
            let health = await service.runOnce()
            let encoded = try encode(health)
            if let destination = healthURL ?? (backgroundMode ? support!.appendingPathComponent("background-health.json") : nil) {
                try writeHealth(encoded, to: destination)
            }
            print(encoded)
            if health.status != .ok && health.status != .noRules {
                exit(1)
            }
        } catch {
            let health = MonitorHealth(status: .configurationError, checkedAt: Date(), evaluatedRules: 0, triggeredRules: 0, message: error.localizedDescription)
            print((try? encode(health)) ?? "{\"status\":\"configurationError\"}")
            exit(1)
        }
    }

    private static func encode(_ health: MonitorHealth) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return String(data: try encoder.encode(health), encoding: .utf8) ?? "{}"
    }

    private static func value(after flag: String, in arguments: ArraySlice<String>) -> String? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        let next = arguments.index(after: index)
        guard next < arguments.endIndex else { return nil }
        return arguments[next]
    }

    private static func writeHealth(_ value: String, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let temporary = directory.appendingPathComponent(".background-health-" + UUID().uuidString + ".tmp")
        do {
            try Data(value.utf8).write(to: temporary, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: url)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}
