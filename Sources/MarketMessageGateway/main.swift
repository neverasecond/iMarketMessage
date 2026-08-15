import Foundation
import MarketMessageCore

@main
struct MarketMessageGateway {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--help") || arguments.contains("-h") {
            print("Usage: iMM-gateway --plan --executable PATH --outbox PATH --pairing PATH --ack PATH")
            print("       iMM-gateway --dry-run --outbox PATH --pairing PATH [--ack PATH]")
            print("       iMM-gateway --send [--outbox PATH --pairing PATH --ack PATH]")
            print("--dry-run is read-only: it validates existing files and never sends, ACKs, moves, deletes, creates, or chmods.")
            print("--send consumes the outbox only after an existing paired-self file is found; it never accepts a recipient argument.")
            return
        }

        do {
            if containsRecipientArgument(arguments) {
                print("Refusing recipient arguments; use the local paired-self setup in iMM.")
                exit(2)
            }

            let hasPlan = arguments.contains("--plan")
            let hasDryRun = arguments.contains("--dry-run")
            let hasSend = arguments.contains("--send")
            guard [hasPlan, hasDryRun, hasSend].filter({ $0 }).count <= 1 else {
                print("Choose exactly one of --plan, --dry-run, or --send.")
                exit(2)
            }
            if containsUnexpectedArgument(arguments) {
                print("Refusing unknown or positional arguments; the gateway accepts no recipient input.")
                exit(2)
            }

            if hasPlan {
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

            guard hasDryRun || hasSend else {
                print("Refusing to run without --dry-run or explicit --send.")
                exit(2)
            }
            if hasSend {
                let support = try JSONRuleStore.applicationSupportDirectory()
                let outbox = optionalURL("--outbox", arguments) ?? support.appendingPathComponent("Outbox", isDirectory: true)
                let pairing = optionalURL("--pairing", arguments) ?? support.appendingPathComponent("paired-self.json")
                let ack = optionalURL("--ack", arguments)
                let sender = PairedSelfIMessageSender(pairingURL: pairing)
                let result = await GatewayOutboxConsumer(
                    outboxURL: outbox,
                    pairingURL: pairing,
                    ackURL: ack,
                    sender: sender
                ).processOnce()
                print(try encode(result))
                if result.waitingForPairing {
                    exit(2)
                }
                if result.error != nil || result.failedCount > 0 || result.rejectedCount > 0 || result.quarantinedCount > 0 {
                    exit(1)
                }
                return
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
            print(try encode(result))
        } catch {
            print("gateway command failed: \(error.localizedDescription)")
            exit(1)
        }
    }

    private static func encode(_ result: GatewayProcessResult) throws -> String {
        let summary: [String: Any] = [
            "waitingForPairing": result.waitingForPairing,
            "sent": result.sentCount,
            "duplicate": result.duplicateCount,
            "failed": result.failedCount,
            "rejected": result.rejectedCount,
            "quarantined": result.quarantinedCount,
            "error": result.error ?? NSNull()
        ]
        let data = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func encode(_ result: GatewayPreviewResult) throws -> String {
        let summary: [String: Any] = [
            "waitingForPairing": result.waitingForPairing,
            "ready": result.readyCount,
            "duplicate": result.duplicateCount,
            "rejected": result.rejectedCount,
            "error": result.error ?? NSNull()
        ]
        let data = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
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

    private static let recipientFlags = [
        "--recipient", "--target", "--to", "--phone", "--contact", "--chat", "--chat-id"
    ]

    private static let valueFlags = ["--executable", "--outbox", "--pairing", "--ack"]

    private static func containsRecipientArgument(_ arguments: [String]) -> Bool {
        arguments.contains { argument in
            recipientFlags.contains(argument) || recipientFlags.contains { argument.hasPrefix($0 + "=") }
        }
    }

    private static func containsUnexpectedArgument(_ arguments: [String]) -> Bool {
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            if argument == "--plan" || argument == "--dry-run" || argument == "--send" {
                index = arguments.index(after: index)
                continue
            }
            if valueFlags.contains(argument) {
                let next = arguments.index(after: index)
                guard next < arguments.endIndex,
                      !arguments[next].hasPrefix("-") else { return true }
                index = arguments.index(after: next)
                continue
            }
            // Keep the parser strict about every other flag or bare argument.
            return true
        }
        return false
    }
}
