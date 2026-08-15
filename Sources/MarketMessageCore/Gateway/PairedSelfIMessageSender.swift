import Foundation
import Darwin

/// The small result returned by the process boundary used by the real
/// transport.  Standard output and error are captured only for the caller;
/// the gateway never prints them because an AppleScript error can contain
/// private recipient or message details.
public struct GatewayProcessOutput: Equatable, Sendable {
    public let terminationStatus: Int32
    public let standardOutput: Data
    public let standardError: Data

    public init(
        terminationStatus: Int32,
        standardOutput: Data = Data(),
        standardError: Data = Data()
    ) {
        self.terminationStatus = terminationStatus
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public enum GatewayProcessError: Error, Equatable, LocalizedError, Sendable {
    case invalidExecutable
    case launchFailed
    case timedOut
    case processFailed

    public var errorDescription: String? {
        switch self {
        case .invalidExecutable: return "gateway transport 可执行文件无效"
        case .launchFailed: return "gateway transport 无法启动"
        case .timedOut: return "gateway transport 执行超时"
        case .processFailed: return "gateway transport 进程失败"
        }
    }
}

/// Injectable boundary around Foundation.Process.  Tests provide a recorder
/// here and therefore never launch `/usr/bin/osascript`.
public protocol GatewayProcessRunner: Sendable {
    func run(executableURL: URL, arguments: [String]) throws -> GatewayProcessOutput
}

/// The production process runner.  It deliberately uses Process arguments
/// directly and never invokes a shell or concatenates an argument string.
public struct SystemGatewayProcessRunner: GatewayProcessRunner, Sendable {
    public static let defaultTimeout: TimeInterval = 30
    public static let defaultTerminationGracePeriod: TimeInterval = 1

    public let timeout: TimeInterval
    public let terminationGracePeriod: TimeInterval

    public init(
        timeout: TimeInterval = SystemGatewayProcessRunner.defaultTimeout,
        terminationGracePeriod: TimeInterval = SystemGatewayProcessRunner.defaultTerminationGracePeriod
    ) {
        // Keep invalid caller input bounded as well.  A zero timeout is useful
        // for tests and intentionally means "do not wait"; NaN/infinite input
        // falls back to the documented finite defaults.
        self.timeout = timeout.isFinite ? max(0, timeout) : Self.defaultTimeout
        self.terminationGracePeriod = terminationGracePeriod.isFinite
            ? max(0, terminationGracePeriod)
            : Self.defaultTerminationGracePeriod
    }

    public func run(executableURL: URL, arguments: [String]) throws -> GatewayProcessOutput {
        guard executableURL.path == PairedSelfIMessageSender.osascriptPath else {
            throw GatewayProcessError.invalidExecutable
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        // Drain both descriptors on independent queues while the child runs.
        // Waiting for the process before reading either pipe can deadlock when
        // osascript emits more than the kernel pipe buffer (notably on errors).
        let outputDrain = GatewayPipeDrain(fileHandle: outputPipe.fileHandleForReading)
        let errorDrain = GatewayPipeDrain(fileHandle: errorPipe.fileHandleForReading)
        let drainGroup = DispatchGroup()
        drainGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            outputDrain.drain()
            drainGroup.leave()
        }
        drainGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            errorDrain.drain()
            drainGroup.leave()
        }

        let termination = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            termination.signal()
        }
        do {
            try process.run()
        } catch {
            outputDrain.close()
            errorDrain.close()
            outputPipe.fileHandleForWriting.closeFile()
            errorPipe.fileHandleForWriting.closeFile()
            _ = drainGroup.wait(timeout: .now() + terminationGracePeriod)
            throw GatewayProcessError.launchFailed
        }

        // The child inherited the write ends during run().  Closing the
        // parent's copies guarantees EOF reaches the drainers when the child
        // exits, even if Foundation retains the Pipe object longer.
        outputPipe.fileHandleForWriting.closeFile()
        errorPipe.fileHandleForWriting.closeFile()

        if termination.wait(timeout: .now() + timeout) == .timedOut {
            terminate(process, termination: termination)
            // A timed-out command is never reported as a successful send.  Do
            // not expose captured stderr: AppleScript diagnostics can contain
            // the paired target or message text.
            outputDrain.close()
            errorDrain.close()
            _ = drainGroup.wait(timeout: .now() + terminationGracePeriod)
            throw GatewayProcessError.timedOut
        }

        // The termination handler has fired, so Foundation has populated the
        // status without requiring an unbounded waitUntilExit call here.
        if drainGroup.wait(timeout: .now() + terminationGracePeriod) == .timedOut {
            // Normally Process closes the child-side descriptors for us.  If a
            // helper inherited one, close our pipe ends and return what was
            // drained instead of waiting forever.
            outputDrain.close()
            errorDrain.close()
            _ = drainGroup.wait(timeout: .now() + terminationGracePeriod)
        }
        return GatewayProcessOutput(
            terminationStatus: process.terminationStatus,
            standardOutput: outputDrain.data,
            standardError: errorDrain.data
        )
    }

    private func terminate(_ process: Process, termination: DispatchSemaphore) {
        guard process.isRunning else {
            _ = termination.wait(timeout: .now() + terminationGracePeriod)
            return
        }

        process.terminate()
        if termination.wait(timeout: .now() + terminationGracePeriod) == .timedOut,
           process.isRunning {
            // `terminate()` is SIGTERM and a stuck AppleScript can ignore it.
            // Escalate only while this Process still owns a live PID, avoiding
            // an unbounded wait and avoiding any shell-based kill command.
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
            _ = termination.wait(timeout: .now() + terminationGracePeriod)
        }
    }
}

/// Thread-safe bounded capture for one Process pipe.  The cap keeps a faulty
/// helper from turning an error path into unbounded memory growth while the
/// reader still continuously drains the kernel pipe.
private final class GatewayPipeDrain: @unchecked Sendable {
    private static let maxCapturedBytes = 1_048_576

    private let fileHandle: FileHandle
    private let lock = NSLock()
    private var captured = Data()

    init(fileHandle: FileHandle) {
        self.fileHandle = fileHandle
    }

    func drain() {
        while true {
            // The throwing API turns a concurrent close (used on timeout) into
            // a clean end-of-stream instead of raising a FileHandle exception.
            guard let chunk = try? fileHandle.read(upToCount: 64 * 1024),
                  !chunk.isEmpty else { return }
            lock.lock()
            if captured.count < Self.maxCapturedBytes {
                let remaining = Self.maxCapturedBytes - captured.count
                captured.append(chunk.prefix(remaining))
            }
            lock.unlock()
        }
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    func close() {
        try? fileHandle.close()
    }
}

/// Injectable message transport boundary.  It receives only a paired target
/// selected by local setup and message text from a validated envelope.
public protocol GatewayMessageTransport: Sendable {
    func send(target: PairedSelfTarget, text: String) async throws
}

public enum GatewayTransportError: Error, Equatable, LocalizedError, Sendable {
    case invalidMessage
    case timedOut
    case processFailed

    public var errorDescription: String? {
        switch self {
        case .invalidMessage: return "gateway 消息文本无效"
        case .timedOut: return "iMessage transport 执行超时"
        case .processFailed: return "iMessage transport 执行失败"
        }
    }
}

/// A fixed AppleScript program for Messages.  Recipient and text are passed
/// as separate Process arguments after `-e`; neither value is interpolated
/// into the script or into a shell command.
public struct AppleScriptIMessageTransport: GatewayMessageTransport, Sendable {
    public let processRunner: any GatewayProcessRunner

    public init(processRunner: any GatewayProcessRunner = SystemGatewayProcessRunner()) {
        self.processRunner = processRunner
    }

    public func send(target: PairedSelfTarget, text: String) async throws {
        let bytes = Data(text.utf8).count
        guard !text.isEmpty, bytes <= GatewayProtocol.maxTextBytes else {
            throw GatewayTransportError.invalidMessage
        }
        let result: GatewayProcessOutput
        do {
            result = try processRunner.run(
                executableURL: URL(fileURLWithPath: PairedSelfIMessageSender.osascriptPath),
                // `--` terminates osascript's option parsing.  Target and
                // text remain independent argv values even when either starts
                // with `-` (for example `--help` or `-e`).
                arguments: ["-e", Self.sendScript, "--", target.rawValue, text]
            )
        } catch let error as GatewayProcessError {
            if error == .timedOut {
                throw GatewayTransportError.timedOut
            }
            throw GatewayTransportError.processFailed
        } catch {
            throw GatewayTransportError.processFailed
        }
        guard result.terminationStatus == 0 else {
            throw GatewayTransportError.processFailed
        }
    }

    /// Keep this body constant.  Do not interpolate target or text here:
    /// AppleScript receives both as independent argv values.
    public static let sendScript = #"""
    on run argv
        if (count of argv) is not 2 then error "invalid gateway arguments"
        set pairedTarget to item 1 of argv
        set messageText to item 2 of argv
        tell application "Messages"
            set targetService to 1st service whose service type is iMessage
            set targetBuddy to buddy pairedTarget of targetService
            send messageText to targetBuddy
        end tell
    end run
    """#
}

/// A real sender that is still constrained to the one local paired-self
/// target.  The `target` parameter required by `GatewayMessageSender` is
/// intentionally ignored: this sender re-reads its own pairing store before
/// every send, so neither an envelope nor a caller can override the target.
public struct PairedSelfIMessageSender: GatewayMessageSender, Sendable {
    public static let osascriptPath = "/usr/bin/osascript"

    public let pairingStore: GatewayPairingStore
    public let transport: any GatewayMessageTransport

    public init(pairingURL: URL, transport: any GatewayMessageTransport = AppleScriptIMessageTransport()) {
        self.pairingStore = GatewayPairingStore(fileURL: pairingURL)
        self.transport = transport
    }

    public init(pairingStore: GatewayPairingStore, transport: any GatewayMessageTransport = AppleScriptIMessageTransport()) {
        self.pairingStore = pairingStore
        self.transport = transport
    }

    public func send(_ envelope: GatewayOutboxEnvelope, to _: PairedSelfTarget) async throws {
        let target: PairedSelfTarget?
        do {
            target = try pairingStore.load()
        } catch {
            throw GatewaySenderError.pairingStateInvalid
        }
        guard let target else {
            throw GatewaySenderError.pairingRequired
        }
        let textBytes = Data(envelope.text.utf8).count
        guard !envelope.text.isEmpty, textBytes <= GatewayProtocol.maxTextBytes else {
            throw GatewaySenderError.invalidEnvelope
        }
        try await transport.send(target: target, text: envelope.text)
    }
}
