import Foundation

public enum ForwardStoreError: Error, LocalizedError {
    /// The file could not be decoded; it was moved aside to `backup` so it is not overwritten.
    case corrupt(backup: URL)
    case unsupportedVersion(Int)
    case writeBlocked(String)

    public var errorDescription: String? {
        switch self {
        case .corrupt(let backup):
            return "数据文件已损坏，已备份到 \(backup.path)，当前从空列表开始。"
        case .unsupportedVersion(let version):
            return "数据文件版本 \(version) 不受支持，已保留原文件，请使用兼容的 SSHCat 版本。"
        case .writeBlocked(let reason):
            return "配置未能载入，已阻止覆盖：\(reason)。请修复文件后重新加载。"
        }
    }
}

/// Reads and writes rule files: directory 0700, file 0600, atomic replace.
public enum SecureFile {
    public static func read(_ url: URL) -> Data? {
        try? Data(contentsOf: url)
    }

    public static func write(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let tmp = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: url)
            }
            // createDirectory's mode is masked by umask; set the modes the plan requires explicitly.
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    /// Moves an undecodable file aside so the next save does not destroy it.
    public static func quarantine(_ url: URL) throws -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let base = url.deletingPathExtension().lastPathComponent
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent("\(base).corrupt-\(stamp)-\(UUID().uuidString).json")
        try FileManager.default.moveItem(at: url, to: backup)
        return backup
    }
}

/// Persists forward rules as `{"version": 1, "rules": [...]}`.
public final class ForwardStore: @unchecked Sendable {
    private struct FileFormat: Codable {
        var version: Int
        var rules: [ForwardRule]
    }

    private struct Version: Decodable {
        var version: Int
    }

    public static let currentVersion = 1

    public let directory: URL
    private var loadFailure: String?
    public var fileURL: URL { directory.appendingPathComponent("forwards.json") }

    public init(directory: URL) {
        self.directory = directory
    }

    public static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SSHCat", isDirectory: true)
    }

    public func load() throws -> [ForwardRule] {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            let code = (error as? CocoaError)?.code
            if code == .fileReadNoSuchFile || code == .fileNoSuchFile {
                loadFailure = nil
                return []
            }
            loadFailure = error.localizedDescription
            throw error
        }

        do {
            let version = try JSONDecoder().decode(Version.self, from: data).version
            guard version == Self.currentVersion else {
                throw ForwardStoreError.unsupportedVersion(version)
            }
            let rules = try JSONDecoder().decode(FileFormat.self, from: data).rules
            loadFailure = nil
            return rules
        } catch let error as ForwardStoreError {
            loadFailure = error.localizedDescription
            throw error
        } catch {
            let backup: URL
            do {
                backup = try SecureFile.quarantine(fileURL)
            } catch {
                loadFailure = error.localizedDescription
                throw error
            }
            loadFailure = nil
            throw ForwardStoreError.corrupt(backup: backup)
        }
    }

    public func save(_ rules: [ForwardRule]) throws {
        if let loadFailure {
            throw ForwardStoreError.writeBlocked(loadFailure)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try SecureFile.write(encoder.encode(FileFormat(version: Self.currentVersion, rules: rules)), to: fileURL)
    }
}
