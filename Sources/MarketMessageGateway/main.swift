import Foundation
import MarketMessageCore

@main
struct MarketMessageGateway {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--help") || arguments.contains("-h") {
            print("Usage: iMM-gateway --plan --executable PATH --outbox PATH --pairing PATH --ack PATH")
            print("       iMM-gateway --dry-run --outbox PATH --pairing PATH [--ack PATH]")
            print("--dry-run is read-only: it validates existing files and never sends, ACKs, moves, deletes, creates, or chmods.")
            print("This beta contains no real sender, pairing UI/command, or install action.")
            return
        }

        do {
            if arguments.contains("--plan") {
                let executable = try requiredURL("--executable", arguments)
                let outbox = try requiredURL("--outbox", arguments)
                let pairing = try requiredURL("--pairing", arguments)
                let ack = try requiredURL("--ack", arguments)
                let plan = try GatewayInstallManager().dryRunPlan(
                    executableURL: executable,
                    outboxURL: outbox,
                    pairingURL: pairing,
                    ackURL: ack
                )
                print(plan.plist)
                return
            }

            guard arguments.contains("--dry-run") else {
                print("Refusing to run without --dry-run; no real sender is included.")
                exit(2)
            }
            let outbox = try requiredURL("--outbox", arguments)
            let pairing = try requiredURL("--pairing", arguments)
            let ack = optionalURL("--ack", arguments)
            let preview = GatewayOutboxPreview(
                outboxURL: outbox,
                pairingURL: pairing,
                ackURL: ack
            )
            let result = preview.inspect()
            let summary: [String: Any] = [
                "waitingForPairing": result.waitingForPairing,
                "ready": result.readyCount,
                "duplicate": result.duplicateCount,
                "rejected": result.rejectedCount,
                "error": result.error ?? NSNull()
            ]
            let data = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
            print(String(data: data, encoding: .utf8) ?? "{}")
        } catch {
            print("gateway dry-run failed: \(error.localizedDescription)")
            exit(1)
        }
    }

    private static func requiredURL(_ flag: String, _ arguments: [String]) throws -> URL {
        guard let value = optionalValue(flag, arguments), !value.isEmpty else {
            throw GatewayInstallError.emptyPath
        }
        return URL(fileURLWithPath: value)
    }

    private static func optionalURL(_ flag: String, _ arguments: [String]) -> URL? {
        guard let value = optionalValue(flag, arguments), !value.isEmpty else { return nil }
        return URL(fileURLWithPath: value)
    }

    private static func optionalValue(_ flag: String, _ arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.index(after: index) < arguments.endIndex else { return nil }
        return arguments[arguments.index(after: index)]
    }
}
