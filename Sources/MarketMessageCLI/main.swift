import Foundation
import MarketMessageCore

@main
struct MarketMessageCLI {
    static func main() async {
        let arguments = CommandLine.arguments.dropFirst()
        if arguments.contains("--help") || arguments.contains("-h") {
            print("Usage: market-message-cli [--config PATH] [--outbox PATH] [--state PATH]")
            return
        }

        do {
            let configURL = value(after: "--config", in: arguments).map(URL.init(fileURLWithPath:))
            let outboxURL = value(after: "--outbox", in: arguments).map(URL.init(fileURLWithPath:))
            let stateURL = value(after: "--state", in: arguments).map(URL.init(fileURLWithPath:))
            let needsApplicationSupport = configURL == nil || outboxURL == nil || stateURL == nil
            let support = needsApplicationSupport ? try JSONRuleStore.applicationSupportDirectory() : nil
            let config = configURL ?? support!.appendingPathComponent("rules.json")
            let outbox = outboxURL ?? support!.appendingPathComponent("Outbox", isDirectory: true)
            let state = stateURL ?? support!.appendingPathComponent("runtime-state.json")
            let store = JSONRuleStore(fileURL: config)

            let providers: [String: any MarketDataProvider] = [
                "cboe-vix": CboeVIXProvider(),
                "alpha-vantage": AlphaVantageProvider(keyStore: KeychainAPIKeyStore())
            ]
            let service = MonitoringService(
                ruleStore: store,
                providers: providers,
                sink: GatewayOutboxSink(directoryURL: outbox),
                stateURL: state
            )
            let health = await service.runOnce()
            print(try encode(health))
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
}
