import Foundation

public struct OutboxMessage: Codable, Equatable, Sendable {
    public let source: String
    public let id: String
    public let text: String

    public init(source: String, id: String = UUID().uuidString, text: String) {
        self.source = source
        self.id = id
        self.text = text
    }
}

public enum NotificationSinkError: Error, Equatable, LocalizedError, Sendable {
    case emptyMessage
    case messageTooLong(limit: Int)
    case invalidIdentifier
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .emptyMessage: return "通知内容不能为空"
        case .messageTooLong(let limit): return "通知超过 " + String(limit) + " 字节限制"
        case .invalidIdentifier: return "通知 ID 不是安全文件名"
        case .writeFailed(let message): return "通知写入失败：" + message
        }
    }
}

public protocol NotificationSink: Sendable {
    func send(_ message: OutboxMessage) async throws
}

public struct GatewayOutboxSink: NotificationSink {
    public let directoryURL: URL
    public let source: String
    public let maxMessageBytes: Int

    public init(directoryURL: URL, source: String = "market-message", maxMessageBytes: Int = 4_000) {
        self.directoryURL = directoryURL
        // The gateway protocol has one producer source and one hard byte
        // ceiling.  Keep the arguments for source compatibility, but do not
        // allow a caller to widen or replace the wire contract.
        _ = source
        self.source = GatewayProtocol.source
        self.maxMessageBytes = min(maxMessageBytes, GatewayProtocol.maxTextBytes)
    }

    public func send(_ message: OutboxMessage) async throws {
        let textData = Data(message.text.utf8)
        guard !textData.isEmpty else { throw NotificationSinkError.emptyMessage }
        guard textData.count <= maxMessageBytes else { throw NotificationSinkError.messageTooLong(limit: maxMessageBytes) }
        guard Self.isSafeIdentifier(message.id) else { throw NotificationSinkError.invalidIdentifier }
        let stored = OutboxMessage(source: source, id: message.id, text: message.text)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(stored)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: GatewayProtocol.directoryPermissions], ofItemAtPath: directoryURL.path)
            let finalURL = directoryURL.appendingPathComponent("\(message.id).json")
            let temporaryURL = directoryURL.appendingPathComponent(".\(message.id).tmp-\(UUID().uuidString)")
            try data.write(to: temporaryURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: GatewayProtocol.filePermissions], ofItemAtPath: temporaryURL.path)
            if FileManager.default.fileExists(atPath: finalURL.path) {
                _ = try FileManager.default.replaceItemAt(finalURL, withItemAt: temporaryURL)
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
            }
            try FileManager.default.setAttributes([.posixPermissions: GatewayProtocol.filePermissions], ofItemAtPath: finalURL.path)
        } catch let error as NotificationSinkError {
            throw error
        } catch {
            throw NotificationSinkError.writeFailed(error.localizedDescription)
        }
    }

    private static func isSafeIdentifier(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}

public actor MockNotificationSink: NotificationSink {
    public private(set) var messages: [OutboxMessage] = []

    public init() {}

    public func send(_ message: OutboxMessage) async throws {
        messages.append(message)
    }

    public func allMessages() -> [OutboxMessage] { messages }
}
