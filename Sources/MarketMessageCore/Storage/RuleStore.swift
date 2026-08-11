import Foundation

public enum RuleStoreError: Error, Equatable, LocalizedError, Sendable {
    case invalidLocation
    case invalidDocument(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidLocation: return "规则存储路径无效"
        case .invalidDocument(let message): return "规则文件无效：" + message
        case .writeFailed(let message): return "规则写入失败：" + message
        }
    }
}

public protocol RuleStore: Sendable {
    func load() throws -> RuleSet
    func save(_ ruleSet: RuleSet) throws
}

public struct JSONRuleStore: RuleStore {
    public let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL) {
        self.fileURL = fileURL
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public static func applicationSupportDirectory() throws -> URL {
        let manager = FileManager.default
        guard let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw RuleStoreError.invalidLocation
        }
        return base.appendingPathComponent("MarketMessage", isDirectory: true)
    }

    public static func applicationSupport() throws -> JSONRuleStore {
        JSONRuleStore(fileURL: try applicationSupportDirectory().appendingPathComponent("rules.json"))
    }

    public func load() throws -> RuleSet {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return RuleSet() }
        do {
            let data = try Data(contentsOf: fileURL)
            let result = try decoder.decode(RuleSet.self, from: data)
            guard result.version == 1 else { throw RuleStoreError.invalidDocument("不支持的 version") }
            return result
        } catch let error as RuleStoreError {
            throw error
        } catch {
            throw RuleStoreError.invalidDocument(error.localizedDescription)
        }
    }

    public func save(_ ruleSet: RuleSet) throws {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let data = try encoder.encode(ruleSet)
            let temporaryURL = directory.appendingPathComponent(".rules-\(UUID().uuidString).tmp")
            try data.write(to: temporaryURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporaryURL)
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: fileURL)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            throw RuleStoreError.writeFailed(error.localizedDescription)
        }
    }
}
