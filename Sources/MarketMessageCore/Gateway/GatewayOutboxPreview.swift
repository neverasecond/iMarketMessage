import Foundation

public enum GatewayPreviewOutcome: String, Codable, Equatable, Sendable {
    case ready
    case duplicate
    case rejected
}

public struct GatewayPreviewItem: Equatable, Sendable {
    public let id: String
    public let outcome: GatewayPreviewOutcome
    /// A short validation result only; no message body, paired target, or path.
    public let reason: String?

    public init(id: String, outcome: GatewayPreviewOutcome, reason: String? = nil) {
        self.id = id
        self.outcome = outcome
        self.reason = reason
    }
}

public struct GatewayPreviewResult: Equatable, Sendable {
    public let items: [GatewayPreviewItem]
    public let waitingForPairing: Bool
    public let error: String?

    public init(items: [GatewayPreviewItem] = [], waitingForPairing: Bool = false, error: String? = nil) {
        self.items = items
        self.waitingForPairing = waitingForPairing
        self.error = error
    }

    public var readyCount: Int { items.filter { $0.outcome == .ready }.count }
    public var duplicateCount: Int { items.filter { $0.outcome == .duplicate }.count }
    public var rejectedCount: Int { items.filter { $0.outcome == .rejected }.count }
}

/// A strictly read-only outbox inspection used by `iMM-gateway --dry-run`.
/// It never creates directories, changes modes, writes ACKs, moves files to
/// quarantine, removes files, or invokes a sender.
public struct GatewayOutboxPreview: Sendable {
    public let outboxURL: URL
    public let pairingURL: URL
    public let ackURL: URL

    public init(outboxURL: URL, pairingURL: URL, ackURL: URL? = nil) {
        self.outboxURL = outboxURL
        self.pairingURL = pairingURL
        self.ackURL = ackURL ?? outboxURL.deletingLastPathComponent().appendingPathComponent("gateway-acks.json")
    }

    public func inspect() -> GatewayPreviewResult {
        guard FileManager.default.fileExists(atPath: outboxURL.path) else {
            return GatewayPreviewResult(error: "outbox not found")
        }
        do {
            try GatewayFileSecurity.requirePrivateDirectory(outboxURL)
        } catch {
            return GatewayPreviewResult(error: "outbox permission check failed")
        }

        let waitingForPairing: Bool
        do {
            waitingForPairing = try GatewayPairingStore(fileURL: pairingURL).load() == nil
        } catch {
            return GatewayPreviewResult(error: "pairing state check failed")
        }

        let records: [String: GatewayAckRecord]
        do {
            records = try GatewayAckStore(fileURL: ackURL).load()
        } catch {
            return GatewayPreviewResult(error: "ack state check failed")
        }

        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: outboxURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            .filter { $0.pathExtension.lowercased() == "json" }
            .filter { !sameFile($0, ackURL) && !sameFile($0, pairingURL) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            return GatewayPreviewResult(error: "outbox listing failed")
        }

        var items: [GatewayPreviewItem] = []
        for file in files {
            let filenameID = file.deletingPathExtension().lastPathComponent
            let id = GatewayProtocol.isSafeIdentifier(filenameID) ? filenameID : "unknown"
            do {
                try GatewayFileSecurity.requirePrivateFile(file)
                let envelope = try GatewayOutboxEnvelope.decodeStrict(
                    try Data(contentsOf: file),
                    filename: file.lastPathComponent
                )
                if records[envelope.id]?.status == .sent {
                    items.append(GatewayPreviewItem(id: envelope.id, outcome: .duplicate))
                } else {
                    items.append(GatewayPreviewItem(id: envelope.id, outcome: .ready))
                }
            } catch {
                items.append(GatewayPreviewItem(id: id, outcome: .rejected, reason: "schema or permission rejected"))
            }
        }
        return GatewayPreviewResult(items: items, waitingForPairing: waitingForPairing)
    }

    private func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
    }
}

