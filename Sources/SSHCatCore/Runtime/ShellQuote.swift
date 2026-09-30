import Foundation

public enum ShellQuote {
    /// Quote one argv element for display. The process itself is never launched through a shell.
    public static func quote(_ s: String) -> String {
        if s.isEmpty { return "''" }
        let plain = s.allSatisfy { ch in
            ch.isLetter || ch.isNumber || "-_./:@".contains(ch)
        }
        if plain { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func join(_ parts: [String]) -> String {
        parts.map(quote).joined(separator: " ")
    }
}
