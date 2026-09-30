import Foundation

/// Host names suggested from `~/.ssh/config`. Patterns (`*`, `?`) and negations are skipped:
/// the real Port, IdentityFile, and ProxyJump still come from ssh itself when those fields are empty.
public enum SSHConfigHosts {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
    }

    public static func load(from url: URL = defaultURL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parse(text)
    }

    public static func parse(_ text: String) -> [String] {
        var hosts: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let code = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first
                .map(String.init) ?? ""
            let tokens = code.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let keyword = tokens.first?.lowercased(), keyword == "host" else { continue }
            for token in tokens.dropFirst() {
                let name = Self.unquote(token)
                if name.contains("*") || name.contains("?") || name.hasPrefix("!") { continue }
                if !hosts.contains(name) { hosts.append(name) }
            }
        }
        return hosts
    }

    /// `Host "name"` is one token including the quotes; the picker should show the name.
    private static func unquote(_ token: String) -> String {
        guard token.count >= 2, token.hasPrefix("\""), token.hasSuffix("\"") else { return token }
        return String(token.dropFirst().dropLast())
    }
}
