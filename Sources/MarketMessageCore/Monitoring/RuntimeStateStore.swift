import Foundation

public enum RuntimeStateStoreError: Error, Equatable, LocalizedError, Sendable {
    case readFailed(String)
    case invalidDocument(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .readFailed(let message): return "运行状态读取失败：" + message
        case .invalidDocument(let message): return "运行状态文件无效：" + message
        case .writeFailed(let message): return "运行状态保存失败：" + message
        }
    }
}

/// Persists only non-sensitive rule evaluation state. The directory and file
/// are private to the current user so a gateway cannot accidentally read it
/// through a shared outbox path.
public struct RuntimeStateStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> [String: RuleRuntimeState] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([String: RuleRuntimeState].self, from: data)
        } catch let error as RuntimeStateStoreError {
            throw error
        } catch {
            if (error as NSError).domain == NSCocoaErrorDomain {
                throw RuntimeStateStoreError.readFailed(error.localizedDescription)
            }
            throw RuntimeStateStoreError.invalidDocument(error.localizedDescription)
        }
    }

    public func save(_ state: [String: RuleRuntimeState]) throws {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(state)
            let temporaryURL = directory.appendingPathComponent(".runtime-state-\(UUID().uuidString).tmp")
            try data.write(to: temporaryURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporaryURL)
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: fileURL)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch let error as RuntimeStateStoreError {
            throw error
        } catch {
            throw RuntimeStateStoreError.writeFailed(error.localizedDescription)
        }
    }
}
