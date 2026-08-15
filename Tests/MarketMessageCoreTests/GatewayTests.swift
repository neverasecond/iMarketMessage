import Foundation
import Testing
@testable import MarketMessageCore

struct GatewayTests {
    @Test func pairingIsFirstSetupOnlyAndPrivate() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pairingURL = directory.appendingPathComponent("paired-self.json")
        let store = GatewayPairingStore(fileURL: pairingURL)
        let target = try PairedSelfTarget(rawValue: "local-self")

        try store.firstSetup(target: target)
        #expect(try store.load() == target)
        let attributes = try FileManager.default.attributesOfItem(atPath: pairingURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)

        do {
            try store.firstSetup(target: try PairedSelfTarget(rawValue: "other"))
            Issue.record("pairing target was unexpectedly overwritten")
        } catch let error as GatewayStorageError {
            #expect(error == .alreadyPaired)
        }
    }

    @Test func pairingResetRequiresTheStoreAndAllowsAFreshFirstSetup() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pairingURL = directory.appendingPathComponent("paired-self.json")
        let store = GatewayPairingStore(fileURL: pairingURL)
        try store.firstSetup(target: try PairedSelfTarget(rawValue: "local-self"))
        try store.reset()
        #expect(try store.load() == nil)
        try store.firstSetup(target: try PairedSelfTarget(rawValue: "local-self-2"))
        #expect(try store.load() == PairedSelfTarget(rawValue: "local-self-2"))
    }

    @Test func strictEnvelopeRejectsUnknownFieldsAndEnforcesFourKilobytes() throws {
        let unknown = Data("{\"id\":\"safe\",\"source\":\"market-message\",\"text\":\"ok\",\"recipient\":\"x\"}".utf8)
        do {
            _ = try GatewayOutboxEnvelope.decodeStrict(unknown, filename: "safe.json")
            Issue.record("unknown envelope field was accepted")
        } catch let error as GatewayEnvelopeError {
            #expect(error == .schemaMismatch)
        }

        let oversized = GatewayOutboxEnvelope(id: "safe", text: String(repeating: "x", count: 4_001))
        let data = try JSONEncoder().encode(oversized)
        do {
            _ = try GatewayOutboxEnvelope.decodeStrict(data, filename: "safe.json")
            Issue.record("oversized envelope was accepted")
        } catch let error as GatewayEnvelopeError {
            #expect(error == .textTooLong(limit: 4_000))
        }
    }

    @Test func envelopeFilenameAndRecipientKeysCannotReachTransport() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outboxURL = directory.appendingPathComponent("outbox", isDirectory: true)
        try FileManager.default.createDirectory(at: outboxURL, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: outboxURL.path)
        let pairingURL = directory.appendingPathComponent("paired-self.json")
        try GatewayPairingStore(fileURL: pairingURL).firstSetup(target: try PairedSelfTarget(rawValue: "local-self"))

        let extraKey = outboxURL.appendingPathComponent("extra.json")
        try Data("{\"source\":\"market-message\",\"id\":\"extra\",\"text\":\"hello\",\"recipient\":\"attacker\"}".utf8).write(to: extraKey)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: extraKey.path)
        let mismatch = outboxURL.appendingPathComponent("filename.json")
        try Data("{\"source\":\"market-message\",\"id\":\"other\",\"text\":\"hello\"}".utf8).write(to: mismatch)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: mismatch.path)

        let runner = RecordingGatewayProcessRunner()
        let sender = PairedSelfIMessageSender(
            pairingURL: pairingURL,
            transport: AppleScriptIMessageTransport(processRunner: runner)
        )
        let result = await GatewayOutboxConsumer(
            outboxURL: outboxURL,
            pairingURL: pairingURL,
            sender: sender
        ).processOnce()
        #expect(result.quarantinedCount == 2)
        #expect(runner.callCount() == 0)
    }

    @Test func pairedSelfSenderReReadsStoreAndPassesSafeIndependentArgv() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pairingURL = directory.appendingPathComponent("paired-self.json")
        let stored = try PairedSelfTarget(rawValue: "--help")
        try GatewayPairingStore(fileURL: pairingURL).firstSetup(target: stored)
        let runner = RecordingGatewayProcessRunner()
        let sender = PairedSelfIMessageSender(
            pairingURL: pairingURL,
            transport: AppleScriptIMessageTransport(processRunner: runner)
        )
        let envelope = GatewayOutboxEnvelope(id: "safe", text: "行情 ; echo should-not-run")
        let forged = try PairedSelfTarget(rawValue: "attacker")

        try await sender.send(envelope, to: forged)

        let invocation = try #require(runner.invocation())
        #expect(invocation.executable == "/usr/bin/osascript")
        #expect(invocation.arguments.count == 5)
        #expect(invocation.arguments[0] == "-e")
        #expect(invocation.arguments[1] == AppleScriptIMessageTransport.sendScript)
        #expect(invocation.arguments[2] == "--")
        #expect(invocation.arguments[3] == stored.rawValue)
        #expect(invocation.arguments[4] == envelope.text)
        #expect(!invocation.arguments[1].contains(stored.rawValue))
        #expect(!invocation.arguments[1].contains(envelope.text))
    }

    @Test func pairedSelfSenderFailsClosedWithoutPairingOrOnTransportFailure() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pairingURL = directory.appendingPathComponent("paired-self.json")
        let runner = RecordingGatewayProcessRunner(status: 1)
        let sender = PairedSelfIMessageSender(
            pairingURL: pairingURL,
            transport: AppleScriptIMessageTransport(processRunner: runner)
        )
        do {
            try await sender.send(
                GatewayOutboxEnvelope(id: "safe", text: "hello"),
                to: try PairedSelfTarget(rawValue: "forged")
            )
            Issue.record("unpaired sender unexpectedly succeeded")
        } catch let error as GatewaySenderError {
            #expect(error == .pairingRequired)
        }
        #expect(runner.callCount() == 0)

        try GatewayPairingStore(fileURL: pairingURL).firstSetup(target: try PairedSelfTarget(rawValue: "local-self"))
        do {
            try await sender.send(
                GatewayOutboxEnvelope(id: "safe", text: "hello"),
                to: try PairedSelfTarget(rawValue: "forged")
            )
            Issue.record("failed transport unexpectedly succeeded")
        } catch let error as GatewayTransportError {
            #expect(error == .processFailed)
        }
        #expect(runner.callCount() == 1)
    }

    @Test func outboxConsumerSendsToPairedSelfAndDeduplicatesACK() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outboxURL = directory.appendingPathComponent("outbox", isDirectory: true)
        let pairingURL = directory.appendingPathComponent("paired-self.json")
        let ackURL = directory.appendingPathComponent("acks.json")
        try GatewayPairingStore(fileURL: pairingURL).firstSetup(target: try PairedSelfTarget(rawValue: "local-self"))
        let sender = RecordingGatewaySender()
        let sink = GatewayOutboxSink(directoryURL: outboxURL)
        let envelope = OutboxMessage(source: "ignored", id: "rule-abc", text: "VIX alert")
        try await sink.send(envelope)
        let consumer = GatewayOutboxConsumer(outboxURL: outboxURL, pairingURL: pairingURL, ackURL: ackURL, sender: sender)

        let first = await consumer.processOnce()
        #expect(first.sentCount == 1)
        #expect(await sender.ids() == ["rule-abc"])
        #expect(await sender.targets() == ["local-self"])
        #expect(try FileManager.default.contentsOfDirectory(at: outboxURL, includingPropertiesForKeys: nil).isEmpty)

        // Recreate the same deterministic ID as a duplicate producer write.
        try await sink.send(envelope)
        let second = await consumer.processOnce()
        #expect(second.duplicateCount == 1)
        #expect(await sender.ids() == ["rule-abc"])
        let ackAttributes = try FileManager.default.attributesOfItem(atPath: ackURL.path)
        #expect((ackAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func senderFailureRetriesThenQuarantines() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outboxURL = directory.appendingPathComponent("outbox", isDirectory: true)
        let pairingURL = directory.appendingPathComponent("paired-self.json")
        let ackURL = directory.appendingPathComponent("acks.json")
        try GatewayPairingStore(fileURL: pairingURL).firstSetup(target: try PairedSelfTarget(rawValue: "local-self"))
        let sender = RecordingGatewaySender(failures: 10)
        try await GatewayOutboxSink(directoryURL: outboxURL).send(OutboxMessage(source: "ignored", id: "rule-fail", text: "retry"))
        let consumer = GatewayOutboxConsumer(
            outboxURL: outboxURL,
            pairingURL: pairingURL,
            ackURL: ackURL,
            retryPolicy: GatewayRetryPolicy(maxAttempts: 2),
            sender: sender
        )

        let first = await consumer.processOnce()
        #expect(first.failedCount == 1)
        let second = await consumer.processOnce()
        #expect(second.quarantinedCount == 1)
        let quarantine = outboxURL.appendingPathComponent("Quarantine", isDirectory: true)
        #expect(try FileManager.default.contentsOfDirectory(at: quarantine, includingPropertiesForKeys: nil).count == 1)
        #expect(await sender.attemptCount() == 2)
    }

    @Test func malformedEnvelopeIsolatedWithoutSender() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outboxURL = directory.appendingPathComponent("outbox", isDirectory: true)
        try FileManager.default.createDirectory(at: outboxURL, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: outboxURL.path)
        let invalidURL = outboxURL.appendingPathComponent("bad.json")
        try Data("{\"source\":\"wrong\",\"id\":\"bad\",\"text\":\"x\"}".utf8).write(to: invalidURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: invalidURL.path)
        let pairingURL = directory.appendingPathComponent("paired-self.json")
        try GatewayPairingStore(fileURL: pairingURL).firstSetup(target: try PairedSelfTarget(rawValue: "local-self"))
        let sender = RecordingGatewaySender()
        let result = await GatewayOutboxConsumer(outboxURL: outboxURL, pairingURL: pairingURL, sender: sender).processOnce()
        #expect(result.quarantinedCount == 1)
        #expect(await sender.attemptCount() == 0)
    }

    @Test func consumerWaitsForLocalPairingWithoutSending() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outboxURL = directory.appendingPathComponent("outbox", isDirectory: true)
        try await GatewayOutboxSink(directoryURL: outboxURL).send(
            OutboxMessage(source: "ignored", id: "rule-unpaired", text: "queued")
        )
        let sender = RecordingGatewaySender()
        let result = await GatewayOutboxConsumer(
            outboxURL: outboxURL,
            pairingURL: directory.appendingPathComponent("paired-self.json"),
            sender: sender
        ).processOnce()
        #expect(result.waitingForPairing)
        #expect(await sender.attemptCount() == 0)
        #expect(try FileManager.default.contentsOfDirectory(at: outboxURL, includingPropertiesForKeys: nil).count == 1)
    }

    @Test func insecureOutboxDirectoryIsNotConsumed() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outboxURL = directory.appendingPathComponent("outbox", isDirectory: true)
        try FileManager.default.createDirectory(at: outboxURL, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: outboxURL.path)
        let pairingURL = directory.appendingPathComponent("paired-self.json")
        try GatewayPairingStore(fileURL: pairingURL).firstSetup(target: try PairedSelfTarget(rawValue: "local-self"))
        let sender = RecordingGatewaySender()
        let result = await GatewayOutboxConsumer(outboxURL: outboxURL, pairingURL: pairingURL, sender: sender).processOnce()
        #expect(result.error == "outbox permission check failed")
        #expect(await sender.attemptCount() == 0)
    }

    @Test func installManagerOnlyReturnsDryRunPlan() throws {
        let plan = try GatewayInstallManager().dryRunPlan(
            executableURL: URL(fileURLWithPath: "/tmp/iMM-gateway"),
            outboxURL: URL(fileURLWithPath: "/tmp/outbox"),
            pairingURL: URL(fileURLWithPath: "/tmp/paired-self.json"),
            ackURL: URL(fileURLWithPath: "/tmp/acks.json")
        )
        #expect(plan.plist.contains("<string>--dry-run</string>"))
        #expect(plan.plist.contains("com.imarketmessage.gateway"))
        #expect(!FileManager.default.fileExists(atPath: "/tmp/com.imarketmessage.gateway.plist"))
    }

    @Test func dryRunPreviewIsReadOnlyAndDoesNotACKOrQuarantine() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outboxURL = directory.appendingPathComponent("outbox", isDirectory: true)
        let pairingURL = directory.appendingPathComponent("paired-self.json")
        let ackURL = directory.appendingPathComponent("acks.json")
        try GatewayPairingStore(fileURL: pairingURL).firstSetup(target: try PairedSelfTarget(rawValue: "local-self"))
        try await GatewayOutboxSink(directoryURL: outboxURL).send(
            OutboxMessage(source: "ignored", id: "rule-preview", text: "preview only")
        )
        let before = try fileTreeSnapshot(directory)

        let result = GatewayOutboxPreview(outboxURL: outboxURL, pairingURL: pairingURL, ackURL: ackURL).inspect()
        #expect(result.readyCount == 1)
        #expect(!result.waitingForPairing)
        #expect(!FileManager.default.fileExists(atPath: ackURL.path))
        #expect(!FileManager.default.fileExists(atPath: outboxURL.appendingPathComponent("Quarantine").path))
        #expect(try fileTreeSnapshot(directory) == before)
    }

    @Test func dryRunSenderIsNeverASuccessfulSend() async throws {
        let target = try PairedSelfTarget(rawValue: "local-self")
        do {
            try await DryRunGatewaySender().send(
                GatewayOutboxEnvelope(id: "rule-preview", text: "preview only"),
                to: target
            )
            Issue.record("dry-run sender unexpectedly succeeded")
        } catch let error as GatewaySenderError {
            #expect(error == .unavailableInBeta)
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("iMM-GatewayTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func fileTreeSnapshot(_ root: URL) throws -> [String: Data] {
        var snapshot: [String: Data] = [:]
        let rootAttributes = try FileManager.default.attributesOfItem(atPath: root.path)
        let rootMode = (rootAttributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
        snapshot["."] = Data("directory:\(rootMode)".utf8)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return snapshot }
        for case let item as URL in enumerator {
            let relative = String(item.path.dropFirst(root.path.count + 1))
            let attributes = try FileManager.default.attributesOfItem(atPath: item.path)
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
            let type = attributes[.type] as? FileAttributeType
            if type == .typeDirectory {
                snapshot[relative] = Data("directory:\(mode)".utf8)
            } else {
                snapshot[relative] = Data("file:\(mode):".utf8) + (try Data(contentsOf: item))
            }
        }
        return snapshot
    }
}

private actor RecordingGatewaySender: GatewayMessageSender {
    private var failuresRemaining: Int
    private var sentIDs: [String] = []
    private var targetValues: [String] = []
    private var attempts = 0

    init(failures: Int = 0) {
        self.failuresRemaining = failures
    }

    func send(_ envelope: GatewayOutboxEnvelope, to target: PairedSelfTarget) async throws {
        attempts += 1
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw NSError(domain: "test-sender", code: 1)
        }
        sentIDs.append(envelope.id)
        targetValues.append(target.rawValue)
    }

    func ids() -> [String] { sentIDs }
    func targets() -> [String] { targetValues }
    func attemptCount() -> Int { attempts }
}

private final class RecordingGatewayProcessRunner: GatewayProcessRunner, @unchecked Sendable {
    struct Invocation: Equatable, Sendable {
        let executable: String
        let arguments: [String]
    }

    private let lock = NSLock()
    private let status: Int32
    private var calls: [Invocation] = []

    init(status: Int32 = 0) {
        self.status = status
    }

    func run(executableURL: URL, arguments: [String]) throws -> GatewayProcessOutput {
        lock.lock()
        calls.append(Invocation(executable: executableURL.path, arguments: arguments))
        lock.unlock()
        return GatewayProcessOutput(terminationStatus: status)
    }

    func invocation() -> Invocation? {
        lock.lock(); defer { lock.unlock() }
        return calls.last
    }

    func callCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return calls.count
    }
}
