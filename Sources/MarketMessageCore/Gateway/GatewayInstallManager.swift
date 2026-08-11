import Foundation

public enum GatewayInstallError: Error, Equatable, LocalizedError, Sendable {
    case relativePath
    case emptyPath
    case invalidLabel

    public var errorDescription: String? {
        switch self {
        case .relativePath: return "后台 gateway 路径必须是绝对路径"
        case .emptyPath: return "后台 gateway 路径不能为空"
        case .invalidLabel: return "后台 gateway label 无效"
        }
    }
}

/// A reviewable launchd plan.  Generating a plan never writes a plist, calls
/// launchctl, installs a LaunchAgent, or starts a service.
public struct GatewayInstallPlan: Equatable, Sendable {
    public let label: String
    public let executableURL: URL
    public let outboxURL: URL
    public let pairingURL: URL
    public let ackURL: URL
    public let plist: String

    public init(label: String, executableURL: URL, outboxURL: URL, pairingURL: URL, ackURL: URL, plist: String) {
        self.label = label
        self.executableURL = executableURL
        self.outboxURL = outboxURL
        self.pairingURL = pairingURL
        self.ackURL = ackURL
        self.plist = plist
    }
}

public struct GatewayInstallManager: Sendable {
    public static let defaultLabel = "com.imarketmessage.gateway"

    public init() {}

    public func dryRunPlan(
        executableURL: URL,
        outboxURL: URL,
        pairingURL: URL,
        ackURL: URL,
        label: String = GatewayInstallManager.defaultLabel,
        startInterval: Int = 30
    ) throws -> GatewayInstallPlan {
        guard !executableURL.path.isEmpty, !outboxURL.path.isEmpty,
              !pairingURL.path.isEmpty, !ackURL.path.isEmpty
        else { throw GatewayInstallError.emptyPath }
        guard executableURL.path.hasPrefix("/"), outboxURL.path.hasPrefix("/"),
              pairingURL.path.hasPrefix("/"), ackURL.path.hasPrefix("/")
        else { throw GatewayInstallError.relativePath }
        guard isSafeLabel(label) else { throw GatewayInstallError.invalidLabel }

        let interval = max(10, startInterval)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(xmlEscape(label))</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(xmlEscape(executableURL.path))</string>
                <string>--dry-run</string>
                <string>--outbox</string>
                <string>\(xmlEscape(outboxURL.path))</string>
                <string>--pairing</string>
                <string>\(xmlEscape(pairingURL.path))</string>
                <string>--ack</string>
                <string>\(xmlEscape(ackURL.path))</string>
            </array>
            <key>StartInterval</key>
            <integer>\(interval)</integer>
            <key>RunAtLoad</key>
            <false/>
            <key>StandardOutPath</key>
            <string>/dev/null</string>
            <key>StandardErrorPath</key>
            <string>/dev/null</string>
        </dict>
        </plist>
        """
        return GatewayInstallPlan(
            label: label,
            executableURL: executableURL,
            outboxURL: outboxURL,
            pairingURL: pairingURL,
            ackURL: ackURL,
            plist: plist
        )
    }

    private func isSafeLabel(_ label: String) -> Bool {
        !label.isEmpty && label.utf8.count <= 128 && label.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_")
        }
    }

    private func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

public typealias GatewayInstallationManager = GatewayInstallManager

