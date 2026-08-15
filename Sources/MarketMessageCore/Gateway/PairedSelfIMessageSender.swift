import Foundation

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

    public var errorDescription: String? {
        switch self {
        case .invalidExecutable: return "gateway transport 可执行文件无效"
        case .launchFailed: return "gateway transport 无法启动"
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
    public init() {}

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
        do {
            try process.run()
        } catch {
            throw GatewayProcessError.launchFailed
        }
        process.waitUntilExit()
        return GatewayProcessOutput(
            terminationStatus: process.terminationStatus,
            standardOutput: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            standardError: errorPipe.fileHandleForReading.readDataToEndOfFile()
        )
    }
}

/// Injectable message transport boundary.  It receives only a paired target
/// selected by local setup and message text from a validated envelope.
public protocol GatewayMessageTransport: Sendable {
    func send(target: PairedSelfTarget, text: String) async throws
}

public enum GatewayTransportError: Error, Equatable, LocalizedError, Sendable {
    case invalidMessage
    case processFailed

    public var errorDescription: String? {
        switch self {
        case .invalidMessage: return "gateway 消息文本无效"
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
