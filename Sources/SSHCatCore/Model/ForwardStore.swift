import Foundation

public enum ForwardStoreError: Error, LocalizedError {
    /// The file could not be decoded; it was moved aside to `backup` so it is not overwritten.
    case corrupt(backup: URL)

    public var errorDescription: String? {
        switch self {
        case .corrupt(let backup):
            return "数据文件已损坏，已备份到 \(backup.path)，当前从空列表开始。"
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
    public static func quarantine(_ url: URL) -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let base = url.deletingPathExtension().lastPathComponent
        let backup = url.deletingLastPathComponent().appendingPathComponent("\(base).corrupt-\(stamp).json")
        try? FileManager.default.moveItem(at: url, to: backup)
        return backup
    }
}

/// Persists forward rules as `{"version": 1, "rules": [...]}`.
public final class ForwardStore: @unchecked Sendable {
    private struct FileFormat: Codable {
        var version: Int
        var rules: [ForwardRule]
    }

    public static let currentVersion = 1

    public let directory: URL
    public var fileURL: URL { directory.appendingPathComponent("forwards.json") }

    public init(directory: URL) {
        self.directory = directory
    }

    public static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SSHCat", isDirectory: true)
    }

    public func load() throws -> [ForwardRule] {
        guard let data = SecureFile.read(fileURL) else { return [] }
        do {
            return try JSONDecoder().decode(FileFormat.self, from: data).rules
        } catch {
            throw ForwardStoreError.corrupt(backup: SecureFile.quarantine(fileURL))
        }
    }

    public func save(_ rules: [ForwardRule]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try SecureFile.write(encoder.encode(FileFormat(version: Self.currentVersion, rules: rules)), to: fileURL)
    }
}
