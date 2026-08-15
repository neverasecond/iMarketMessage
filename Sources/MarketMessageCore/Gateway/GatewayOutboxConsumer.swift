import Foundation

public protocol GatewayMessageSender: Sendable {
    /// Send only to the target supplied by the local pairing store.  The
    /// envelope cannot provide or override a recipient.
    func send(_ envelope: GatewayOutboxEnvelope, to target: PairedSelfTarget) async throws
}

public enum GatewaySenderError: Error, Equatable, LocalizedError, Sendable {
    case unavailableInBeta
    case pairingRequired
    case pairingStateInvalid
    case invalidEnvelope

    public var errorDescription: String? {
        switch self {
        case .unavailableInBeta: return "真实 gateway sender 尚未启用"
        case .pairingRequired: return "gateway 尚未完成 paired-self 配对"
        case .pairingStateInvalid: return "gateway 配对状态无效"
        case .invalidEnvelope: return "gateway envelope 文本无效"
        }
    }
}

/// A guarded sender for callers that explicitly need a no-send value.  It
/// never invokes external I/O and deliberately throws, so a consumer can
/// never turn this no-op into a `sent` ACK. Use `GatewayOutboxPreview` for a
/// truly read-only dry-run; use `PairedSelfIMessageSender` for explicit send.
public struct DryRunGatewaySender: GatewayMessageSender {
    public init() {}

    public func send(_ envelope: GatewayOutboxEnvelope, to target: PairedSelfTarget) async throws {
        _ = envelope
        _ = target
        throw GatewaySenderError.unavailableInBeta
    }
}

public struct GatewayRetryPolicy: Equatable, Sendable {
    public let maxAttempts: Int

    public init(maxAttempts: Int = 3) {
        self.maxAttempts = max(1, maxAttempts)
    }
}

public enum GatewayItemOutcome: String, Codable, Equatable, Sendable {
    case sent
    case duplicate
    case failed
    case rejected
    case quarantined
}

public struct GatewayItemResult: Equatable, Sendable {
    public let id: String
    public let outcome: GatewayItemOutcome
    /// A short, non-sensitive reason.  Message text, target values, and paths
    /// are never included.
    public let reason: String?

    public init(id: String, outcome: GatewayItemOutcome, reason: String? = nil) {
        self.id = id
        self.outcome = outcome
        self.reason = reason
    }
}

public struct GatewayProcessResult: Equatable, Sendable {
    public let items: [GatewayItemResult]
    public let waitingForPairing: Bool
    public let error: String?

    public init(items: [GatewayItemResult] = [], waitingForPairing: Bool = false, error: String? = nil) {
        self.items = items
        self.waitingForPairing = waitingForPairing
        self.error = error
    }

    public var sentCount: Int { items.filter { $0.outcome == .sent }.count }
    public var duplicateCount: Int { items.filter { $0.outcome == .duplicate }.count }
    public var failedCount: Int { items.filter { $0.outcome == .failed }.count }
    public var rejectedCount: Int { items.filter { $0.outcome == .rejected }.count }
    public var quarantinedCount: Int { items.filter { $0.outcome == .quarantined }.count }
}

/// Consumes only completed outbox files.  It has no Messages database access,
/// contact lookup, or recipient input; a sender receives the locally stored
/// paired-self target only.
public actor GatewayOutboxConsumer {
    public let outboxURL: URL
    public let pairingURL: URL
    public let ackURL: URL
    public let quarantineURL: URL
    public let retryPolicy: GatewayRetryPolicy
    private let sender: any GatewayMessageSender

    public init(
        outboxURL: URL,
        pairingURL: URL,
        ackURL: URL? = nil,
        quarantineURL: URL? = nil,
        retryPolicy: GatewayRetryPolicy = GatewayRetryPolicy(),
        sender: any GatewayMessageSender
    ) {
        self.outboxURL = outboxURL
        self.pairingURL = pairingURL
        self.ackURL = ackURL ?? outboxURL.deletingLastPathComponent().appendingPathComponent("gateway-acks.json")
        self.quarantineURL = quarantineURL ?? outboxURL.appendingPathComponent("Quarantine", isDirectory: true)
        self.retryPolicy = retryPolicy
        self.sender = sender
    }

    public func processOnce(now: Date = Date()) async -> GatewayProcessResult {
        _ = now
        do {
            try GatewayFileSecurity.ensurePrivateDirectory(outboxURL)
        } catch {
            return GatewayProcessResult(error: "outbox permission check failed")
        }

        let pairingStore = GatewayPairingStore(fileURL: pairingURL)
        let target: PairedSelfTarget?
        do {
            target = try pairingStore.load()
        } catch {
            return GatewayProcessResult(error: "pairing state check failed")
        }
        guard let target else {
            return GatewayProcessResult(waitingForPairing: true)
        }

        let ackStore = GatewayAckStore(fileURL: ackURL)
        var records: [String: GatewayAckRecord]
        do {
            records = try ackStore.load()
        } catch {
            return GatewayProcessResult(error: "ack state check failed")
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
            return GatewayProcessResult(error: "outbox listing failed")
        }

        var results: [GatewayItemResult] = []
        for file in files {
            let filenameID = file.deletingPathExtension().lastPathComponent
            let safeFilenameID = GatewayProtocol.isSafeIdentifier(filenameID) ? filenameID : "unknown"
            let result = await process(file: file, filenameID: safeFilenameID, target: target, records: &records, ackStore: ackStore)
            results.append(result)
        }
        return GatewayProcessResult(items: results)
    }

    private func process(
        file: URL,
        filenameID: String,
        target: PairedSelfTarget,
        records: inout [String: GatewayAckRecord],
        ackStore: GatewayAckStore
    ) async -> GatewayItemResult {
        do {
            try GatewayFileSecurity.requirePrivateFile(file)
        } catch {
            return reject(file: file, id: filenameID, reason: "file permission rejected", records: &records, ackStore: ackStore)
        }

        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            return reject(file: file, id: filenameID, reason: "file read rejected", records: &records, ackStore: ackStore)
        }

        let envelope: GatewayOutboxEnvelope
        do {
            envelope = try GatewayOutboxEnvelope.decodeStrict(data, filename: file.lastPathComponent)
        } catch {
            return reject(file: file, id: filenameID, reason: "schema rejected", records: &records, ackStore: ackStore)
        }

        if let previous = records[envelope.id], previous.status == .sent {
            try? FileManager.default.removeItem(at: file)
            return GatewayItemResult(id: envelope.id, outcome: .duplicate)
        }
        if let previous = records[envelope.id], previous.status == .quarantined || previous.status == .rejected {
            try? FileManager.default.removeItem(at: file)
            return GatewayItemResult(id: envelope.id, outcome: .duplicate)
        }

        let previousAttempts = records[envelope.id]?.attempts ?? 0
        guard previousAttempts < retryPolicy.maxAttempts else {
            let moved = quarantine(file)
            let record = GatewayAckRecord(
                id: envelope.id,
                status: .quarantined,
                attempts: previousAttempts,
                error: "retry limit reached"
            )
            records[envelope.id] = record
            try? ackStore.save(records)
            return GatewayItemResult(id: envelope.id, outcome: moved ? .quarantined : .failed, reason: "retry limit reached")
        }

        do {
            try await sender.send(envelope, to: target)
        } catch {
            let attempts = previousAttempts + 1
            if attempts >= retryPolicy.maxAttempts {
                let moved = quarantine(file)
                records[envelope.id] = GatewayAckRecord(
                    id: envelope.id,
                    status: .quarantined,
                    attempts: attempts,
                    error: "sender failure"
                )
                try? ackStore.save(records)
                return GatewayItemResult(id: envelope.id, outcome: moved ? .quarantined : .failed, reason: "sender failure")
            }
            records[envelope.id] = GatewayAckRecord(
                id: envelope.id,
                status: .failed,
                attempts: attempts,
                error: "sender failure"
            )
            do {
                try ackStore.save(records)
            } catch {
                return GatewayItemResult(id: envelope.id, outcome: .failed, reason: "ack state write failed")
            }
            return GatewayItemResult(id: envelope.id, outcome: .failed, reason: "sender failure")
        }

        records[envelope.id] = GatewayAckRecord(
            id: envelope.id,
            status: .sent,
            attempts: previousAttempts + 1
        )
        do {
            try ackStore.save(records)
            try FileManager.default.removeItem(at: file)
        } catch {
            return GatewayItemResult(id: envelope.id, outcome: .failed, reason: "ack state write failed")
        }
        return GatewayItemResult(id: envelope.id, outcome: .sent)
    }

    private func reject(
        file: URL,
        id: String,
        reason: String,
        records: inout [String: GatewayAckRecord],
        ackStore: GatewayAckStore
    ) -> GatewayItemResult {
        let moved = quarantine(file)
        if GatewayProtocol.isSafeIdentifier(id), records[id] == nil {
            records[id] = GatewayAckRecord(id: id, status: .rejected, attempts: 0, error: reason)
            try? ackStore.save(records)
        }
        return GatewayItemResult(id: id, outcome: moved ? .quarantined : .rejected, reason: reason)
    }

    private func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
    }

    @discardableResult
    private func quarantine(_ file: URL) -> Bool {
        do {
            try GatewayFileSecurity.ensurePrivateDirectory(quarantineURL)
            let base = file.deletingPathExtension().lastPathComponent
                .filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
            let stem = base.isEmpty ? "invalid" : String(base.prefix(80))
            var destination = quarantineURL.appendingPathComponent(stem + ".json")
            if FileManager.default.fileExists(atPath: destination.path) {
                destination = quarantineURL.appendingPathComponent(stem + "-" + UUID().uuidString + ".json")
            }
            try FileManager.default.moveItem(at: file, to: destination)
            if !GatewayFileSecurity.isSymbolicLink(destination) {
                try FileManager.default.setAttributes([.posixPermissions: GatewayProtocol.filePermissions], ofItemAtPath: destination.path)
            }
            return true
        } catch {
            return false
        }
    }
}
