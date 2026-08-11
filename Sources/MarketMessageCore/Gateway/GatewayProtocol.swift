import Foundation

/// The wire contract between the market monitor and the local companion.
///
/// The contract deliberately has no recipient field.  A companion obtains its
/// paired-self destination from local first-run setup and never from an
/// outbox file.
public enum GatewayProtocol: Sendable {
    public static let source = "market-message"
    public static let schemaVersion = 1
    public static let maxTextBytes = 4_000
    public static let envelopeFields: Set<String> = ["source", "id", "text"]
    public static let filePermissions: Int = 0o600
    public static let directoryPermissions: Int = 0o700

    public static func isSafeIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
        }
    }
}

public struct GatewayOutboxEnvelope: Codable, Equatable, Sendable {
    public let source: String
    public let id: String
    public let text: String

    public init(source: String = GatewayProtocol.source, id: String, text: String) {
        self.source = source
        self.id = id
        self.text = text
    }
}

public enum GatewayEnvelopeError: Error, Equatable, LocalizedError, Sendable {
    case invalidJSON
    case schemaMismatch
    case unsupportedSource
    case invalidIdentifier
    case emptyText
    case textTooLong(limit: Int)
    case filenameMismatch

    public var errorDescription: String? {
        switch self {
        case .invalidJSON: return "outbox JSON 无法解析"
        case .schemaMismatch: return "outbox schema 不匹配"
        case .unsupportedSource: return "outbox source 不受支持"
        case .invalidIdentifier: return "outbox ID 无效"
        case .emptyText: return "outbox 文本为空"
        case .textTooLong(let limit): return "outbox 文本超过字节限制（" + String(limit) + "）"
        case .filenameMismatch: return "outbox 文件名与 ID 不匹配"
        }
    }
}

extension GatewayOutboxEnvelope {
    /// Decode and validate the exact v1 envelope.  JSONDecoder alone is not
    /// sufficient because it accepts unknown keys by default.
    public static func decodeStrict(_ data: Data, filename: String? = nil) throws -> GatewayOutboxEnvelope {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let dictionary = object as? [String: Any],
              Set(dictionary.keys) == GatewayProtocol.envelopeFields,
              dictionary["source"] is String,
              dictionary["id"] is String,
              dictionary["text"] is String
        else {
            throw GatewayEnvelopeError.schemaMismatch
        }

        let decoder = JSONDecoder()
        let envelope: GatewayOutboxEnvelope
        do {
            envelope = try decoder.decode(GatewayOutboxEnvelope.self, from: data)
        } catch {
            throw GatewayEnvelopeError.invalidJSON
        }
        guard envelope.source == GatewayProtocol.source else {
            throw GatewayEnvelopeError.unsupportedSource
        }
        guard GatewayProtocol.isSafeIdentifier(envelope.id) else {
            throw GatewayEnvelopeError.invalidIdentifier
        }
        let textBytes = Data(envelope.text.utf8).count
        guard textBytes > 0 else { throw GatewayEnvelopeError.emptyText }
        guard textBytes <= GatewayProtocol.maxTextBytes else {
            throw GatewayEnvelopeError.textTooLong(limit: GatewayProtocol.maxTextBytes)
        }
        if let filename, filename != envelope.id + ".json" {
            throw GatewayEnvelopeError.filenameMismatch
        }
        return envelope
    }
}

