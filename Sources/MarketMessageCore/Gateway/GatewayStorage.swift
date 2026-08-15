import Foundation

public enum GatewayStorageError: Error, Equatable, LocalizedError, Sendable {
    case missingDirectory
    case insecureDirectory
    case insecureFile
    case notRegularFile
    case invalidPairingState
    case invalidTarget
    case alreadyPaired
    case writeFailed

    public var errorDescription: String? {
        switch self {
        case .missingDirectory: return "gateway 私有目录不存在"
        case .insecureDirectory: return "gateway 私有目录权限不安全"
        case .insecureFile: return "gateway 私有文件权限不安全"
        case .notRegularFile: return "gateway 路径不是普通文件"
        case .invalidPairingState: return "gateway 配对状态无效"
        case .invalidTarget: return "gateway paired-self 目标无效"
        case .alreadyPaired: return "gateway 已完成首次配对，不能覆盖目标"
        case .writeFailed: return "gateway 私有状态写入失败"
        }
    }
}

enum GatewayFileSecurity {
    static func ensurePrivateDirectory(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.createDirectory(
                    at: url,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: GatewayProtocol.directoryPermissions]
                )
            } catch {
                throw GatewayStorageError.writeFailed
            }
        }
        try requirePrivateDirectory(url)
    }

    static func requirePrivateDirectory(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw GatewayStorageError.missingDirectory
        }
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw GatewayStorageError.insecureDirectory
        }
        guard let type = attributes[.type] as? FileAttributeType, type == .typeDirectory,
              let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue,
              permissions == GatewayProtocol.directoryPermissions,
              !isSymbolicLink(url)
        else {
            throw GatewayStorageError.insecureDirectory
        }
    }

    static func requirePrivateFile(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw GatewayStorageError.missingDirectory
        }
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw GatewayStorageError.insecureFile
        }
        guard let type = attributes[.type] as? FileAttributeType, type == .typeRegular,
              let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue,
              permissions == GatewayProtocol.filePermissions,
              !isSymbolicLink(url)
        else {
            throw GatewayStorageError.insecureFile
        }
    }

    static func atomicWrite(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try ensurePrivateDirectory(directory)
        let temporary = directory.appendingPathComponent(".gateway-" + UUID().uuidString + ".tmp")
        do {
            try data.write(to: temporary, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: GatewayProtocol.filePermissions], ofItemAtPath: temporary.path)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: url)
            }
            try FileManager.default.setAttributes([.posixPermissions: GatewayProtocol.filePermissions], ofItemAtPath: url.path)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw GatewayStorageError.writeFailed
        }
    }

    static func isSymbolicLink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}

/// An opaque destination captured by local first-run setup.  It is never
/// read from an outbox envelope and must not be printed or logged.
public struct PairedSelfTarget: Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) throws {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 256,
              !value.contains("\n"), !value.contains("\r"), !value.contains("\0")
        else {
            throw GatewayStorageError.invalidTarget
        }
        self.rawValue = value
    }

    fileprivate init(unchecked value: String) {
        self.rawValue = value
    }
}

public struct GatewayPairingStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Write the paired-self target exactly once.  This is intentionally a
    /// local setup operation; the queue has no API to change the destination.
    public func firstSetup(target: PairedSelfTarget) throws {
        let directory = fileURL.deletingLastPathComponent()
        // First-run setup may be handed an existing Application Support
        // directory created with the user's umask. Tighten it before writing
        // the pairing state; the consumer itself only accepts an already
        // private directory and never relaxes permissions.
        if FileManager.default.fileExists(atPath: directory.path),
           !GatewayFileSecurity.isSymbolicLink(directory) {
            try? FileManager.default.setAttributes(
                [.posixPermissions: GatewayProtocol.directoryPermissions],
                ofItemAtPath: directory.path
            )
        }
        try GatewayFileSecurity.ensurePrivateDirectory(directory)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            throw GatewayStorageError.alreadyPaired
        }
        let object: [String: Any] = ["version": GatewayProtocol.schemaVersion, "target": target.rawValue]
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        } catch {
            throw GatewayStorageError.writeFailed
        }
        try GatewayFileSecurity.atomicWrite(data, to: fileURL)
    }

    public func load() throws -> PairedSelfTarget? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        try GatewayFileSecurity.requirePrivateDirectory(fileURL.deletingLastPathComponent())
        try GatewayFileSecurity.requirePrivateFile(fileURL)
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw GatewayStorageError.invalidPairingState
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              Set(dictionary.keys) == Set(["target", "version"]),
              let version = dictionary["version"] as? Int,
              version == GatewayProtocol.schemaVersion,
              let value = dictionary["target"] as? String,
              let target = try? PairedSelfTarget(rawValue: value)
        else {
            throw GatewayStorageError.invalidPairingState
        }
        return target
    }

    /// Remove an existing paired-self file.  Callers must put this behind an
    /// explicit user-confirmation flow; there is deliberately no CLI reset
    /// flag and firstSetup() still refuses to overwrite an existing file.
    public func reset() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try GatewayFileSecurity.requirePrivateDirectory(fileURL.deletingLastPathComponent())
        try GatewayFileSecurity.requirePrivateFile(fileURL)
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            throw GatewayStorageError.writeFailed
        }
    }
}

public enum GatewayAckStatus: String, Codable, Equatable, Sendable {
    case sent
    case failed
    case rejected
    case quarantined
}

public struct GatewayAckRecord: Codable, Equatable, Sendable {
    public let id: String
    public let status: GatewayAckStatus
    public let attempts: Int
    public let updatedAt: Date
    public let error: String?

    public init(id: String, status: GatewayAckStatus, attempts: Int, updatedAt: Date = Date(), error: String? = nil) {
        self.id = id
        self.status = status
        self.attempts = max(0, attempts)
        self.updatedAt = updatedAt
        self.error = error.map { String($0.prefix(240)) }
    }
}

public struct GatewayAckStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> [String: GatewayAckRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        try GatewayFileSecurity.requirePrivateDirectory(fileURL.deletingLastPathComponent())
        try GatewayFileSecurity.requirePrivateFile(fileURL)
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let state = try decoder.decode(GatewayAckState.self, from: Data(contentsOf: fileURL))
            guard state.version == GatewayProtocol.schemaVersion else {
                throw GatewayStorageError.invalidPairingState
            }
            return state.records
        } catch let error as GatewayStorageError {
            throw error
        } catch {
            throw GatewayStorageError.invalidPairingState
        }
    }

    public func save(_ records: [String: GatewayAckRecord]) throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try GatewayFileSecurity.requirePrivateFile(fileURL)
        }
        let state = GatewayAckState(version: GatewayProtocol.schemaVersion, records: records)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try GatewayFileSecurity.atomicWrite(try encoder.encode(state), to: fileURL)
        } catch let error as GatewayStorageError {
            throw error
        } catch {
            throw GatewayStorageError.writeFailed
        }
    }
}

private struct GatewayAckState: Codable, Sendable {
    let version: Int
    let records: [String: GatewayAckRecord]
}
