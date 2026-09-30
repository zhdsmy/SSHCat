import Foundation

/// Finds ssh. A GUI app launched from Finder gets a minimal PATH, so `/usr/bin/ssh` is tried
/// before PATH. A custom path, when set, wins.
public struct BinaryLocator: Sendable {
    public var customPath: @Sendable () -> String?
    public var fallback: String
    public var environmentPATH: String?
    public var isExecutable: @Sendable (String) -> Bool

    public init(
        customPath: @escaping @Sendable () -> String? = { AppSettings().customBinaryPath },
        fallback: String = "/usr/bin/ssh",
        environmentPATH: String? = ProcessInfo.processInfo.environment["PATH"],
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.customPath = customPath
        self.fallback = fallback
        self.environmentPATH = environmentPATH
        self.isExecutable = isExecutable
    }

    public func locate() -> URL? {
        var candidates: [String] = []
        if let custom = customPath(), !custom.isEmpty { candidates.append(custom) }
        candidates.append(fallback)
        let dirs = environmentPATH?.split(separator: ":").map(String.init) ?? []
        candidates.append(contentsOf: dirs.map { ($0 as NSString).appendingPathComponent("ssh") })

        var seen = Set<String>()
        for path in candidates where seen.insert(path).inserted && isExecutable(path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}
