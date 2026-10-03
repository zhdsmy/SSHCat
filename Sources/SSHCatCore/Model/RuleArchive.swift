import Foundation

public enum RuleArchive {
    private static let maximumBytes = 8 * 1024 * 1024
    private static let maximumRules = 1000

    public enum Duplicates: CaseIterable, Hashable { case skip, copy }

    public enum ImportError: Error, LocalizedError {
        case tooLarge, invalidRule(String, String)
        public var errorDescription: String? {
            switch self {
            case .tooLarge: return L10n.core("import.too_large")
            case .invalidRule(let name, let message): return L10n.core("import.invalid_rule", name, message)
            }
        }
    }

    public static func read(_ url: URL) throws -> [ForwardRule] {
        let info = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard info.isRegularFile == true else { throw CocoaError(.fileReadUnknown) }
        if let size = info.fileSize, size > maximumBytes {
            throw ImportError.tooLarge
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= maximumBytes else { throw ImportError.tooLarge }
        let rules = try ForwardStore.decode(data)
        guard rules.count <= maximumRules else { throw ImportError.tooLarge }
        for rule in rules {
            do { try rule.validate() }
            catch { throw ImportError.invalidRule(rule.name, error.localizedDescription) }
        }
        return rules
    }

    /// Import is additive. Fresh IDs and disabled auto-start prevent accidental replacement or connection.
    public static func prepare(_ incoming: [ForwardRule], existing: [ForwardRule], duplicates: Duplicates) -> [ForwardRule] {
        let repeated = duplicateIndices(incoming, existing: existing)
        var result: [ForwardRule] = []
        for (index, rule) in incoming.enumerated() {
            let duplicate = repeated.contains(index)
            if duplicate && duplicates == .skip { continue }
            var imported = rule.duplicate()
            if !duplicate { imported.name = rule.name }
            result.append(imported)
        }
        return result
    }

    public static func duplicateIndices(_ incoming: [ForwardRule], existing: [ForwardRule]) -> IndexSet {
        // ponytail: imports are capped at 1,000 rules; index fingerprints if that limit grows.
        var seen = existing
        var repeated = IndexSet()
        for (index, rule) in incoming.enumerated() {
            if seen.contains(where: { matches(rule, $0) }) { repeated.insert(index) }
            seen.append(rule)
        }
        return repeated
    }

    private static func matches(_ a: ForwardRule, _ b: ForwardRule) -> Bool {
        if a.id == b.id { return true }
        guard a.forwards.count == b.forwards.count else { return false }
        var normalized = a
        normalized.id = b.id
        normalized.autoStart = b.autoStart
        for index in normalized.forwards.indices { normalized.forwards[index].id = b.forwards[index].id }
        return normalized == b
    }

    public static func export(_ rules: [ForwardRule], to url: URL) throws {
        guard rules.count <= maximumRules else { throw ImportError.tooLarge }
        for rule in rules {
            do { try rule.validate() }
            catch { throw ImportError.invalidRule(rule.name, error.localizedDescription) }
        }
        let data = try ForwardStore.encode(rules)
        // Every exported archive must be readable by the importer. Reject before touching the destination.
        guard data.count <= maximumBytes else { throw ImportError.tooLarge }
        // Export can target Downloads or a shared folder; don't chmod the user's parent directory.
        try SecureFile.write(data, to: url, secureDirectory: false)
    }
}
