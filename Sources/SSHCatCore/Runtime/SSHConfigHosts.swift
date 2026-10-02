import Foundation
import Darwin

/// Host names suggested from `~/.ssh/config`. Patterns (`*`, `?`) and negations are skipped:
/// the real Port, IdentityFile, and ProxyJump still come from ssh itself when those fields are empty.
public enum SSHConfigHosts {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
    }

    private static let maximumIncludeDepth = 16
    private static let maximumConfigFiles = 256
    private static let maximumConfigBytes = 1_048_576

    private enum Directive {
        case host([String])
        case include([String])
    }

    private struct LoadState {
        var visited = Set<String>()
        var hosts: [String] = []
        var hostKeys = Set<String>()
        var fileCount = 0
        var byteCount = 0
    }

    public static func load(from url: URL = defaultURL, includeRoot: URL? = nil) -> [String] {
        let root = (includeRoot ?? defaultURL.deletingLastPathComponent()).standardizedFileURL
        var state = LoadState()
        load(url, relativeTo: root, depth: 0, state: &state)
        return state.hosts
    }

    /// Parses Host entries only; Include lines are ignored by this file-independent API.
    public static func parse(_ text: String) -> [String] {
        var hosts: [String] = []
        var seen = Set<String>()
        collectHosts(from: text, into: &hosts, seen: &seen)
        return hosts
    }

    private static func load(_ url: URL, relativeTo root: URL, depth: Int, state: inout LoadState) {
        guard depth <= maximumIncludeDepth, state.fileCount < maximumConfigFiles else { return }

        let fileURL = url.standardizedFileURL.resolvingSymlinksInPath()
        guard state.visited.insert(fileURL.path).inserted else { return }
        state.fileCount += 1

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let type = attributes[.type] as? FileAttributeType, type == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size >= 0, size <= maximumConfigBytes - state.byteCount,
              let data = try? Data(contentsOf: fileURL), data.count <= maximumConfigBytes - state.byteCount,
              var text = String(data: data, encoding: .utf8) else { return }

        state.byteCount += data.count
        if text.first == "\u{feff}" { text.removeFirst() }

        for directive in directives(in: text) {
            switch directive {
            case .host(let patterns):
                collectHosts(patterns, into: &state.hosts, seen: &state.hostKeys)
            case .include(let patterns):
                for pattern in patterns {
                    for includedURL in includeURLs(pattern, relativeTo: root) {
                        guard state.fileCount < maximumConfigFiles else { return }
                        load(includedURL, relativeTo: root, depth: depth + 1, state: &state)
                    }
                }
            }
        }
    }

    private static func collectHosts(from text: String, into hosts: inout [String], seen: inout Set<String>) {
        for directive in directives(in: text) {
            if case .host(let patterns) = directive {
                collectHosts(patterns, into: &hosts, seen: &seen)
            }
        }
    }

    private static func collectHosts(_ patterns: [String], into hosts: inout [String], seen: inout Set<String>) {
        for name in patterns where !name.isEmpty && !name.contains("*") && !name.contains("?") && !name.hasPrefix("!") {
            if seen.insert(name.lowercased()).inserted { hosts.append(name) }
        }
    }

    private static func directives(in text: String) -> [Directive] {
        text.split(whereSeparator: \.isNewline).compactMap { rawLine in
            guard let tokens = tokenize(String(rawLine)), let first = tokens.first else { return nil }

            let keyword: String
            var values: [String]
            if let equals = first.firstIndex(of: "=") {
                keyword = String(first[..<equals])
                let attached = String(first[first.index(after: equals)...])
                values = attached.isEmpty ? Array(tokens.dropFirst()) : [attached] + tokens.dropFirst()
            } else {
                keyword = first
                values = Array(tokens.dropFirst())
                if let value = values.first, value.hasPrefix("=") {
                    let attached = String(value.dropFirst())
                    if attached.isEmpty { values.removeFirst() }
                    else { values[0] = attached }
                }
                while values.first == "=" { values.removeFirst() }
            }

            switch keyword.lowercased() {
            case "host": return .host(values)
            case "include": return .include(values)
            default: return nil
            }
        }
    }

    private static func tokenize(_ line: String) -> [String]? {
        var tokens: [String] = []
        var token = ""
        var quote: Character?
        var escaped = false
        var hasToken = false

        func finishToken() {
            if hasToken { tokens.append(token); token = ""; hasToken = false }
        }

        for character in line {
            if escaped {
                token.append(character)
                hasToken = true
                escaped = false
            } else if character == "\\", quote != "'" {
                escaped = true
                hasToken = true
            } else if let activeQuote = quote {
                if character == activeQuote { quote = nil }
                else { token.append(character) }
                hasToken = true
            } else if character == "\"" || character == "'" {
                quote = character
                hasToken = true
            } else if character == "#" {
                break
            } else if character.isWhitespace {
                finishToken()
            } else {
                token.append(character)
                hasToken = true
            }
        }

        guard quote == nil, !escaped else { return nil }
        finishToken()
        return tokens
    }

    private static func includeURLs(_ pattern: String, relativeTo root: URL) -> [URL] {
        guard !pattern.isEmpty, !pattern.hasPrefix("~") || pattern == "~" || pattern.hasPrefix("~/") else { return [] }

        let path: String
        if pattern == "~" || pattern.hasPrefix("~/") {
            let home = root.deletingLastPathComponent()
            path = pattern == "~" ? home.path : home.appendingPathComponent(String(pattern.dropFirst(2))).path
        } else if pattern.hasPrefix("/") {
            path = pattern
        } else {
            path = root.appendingPathComponent(pattern).path
        }

        var matches = glob_t()
        matches.gl_matchc = Int32(maximumConfigFiles)
        let result = path.withCString { glob($0, GLOB_LIMIT, nil, &matches) }
        let hitLimit = result == GLOB_NOSPACE && errno == E2BIG
        defer { globfree(&matches) }
        // Darwin can stop a broad glob early. Keep its bounded partial results instead of
        // hiding every host; sorting is needed because glob does not sort on early return.
        guard result == 0 || hitLimit else { return [] }

        return (0..<Int(matches.gl_pathc)).compactMap { index in
            guard let item = matches.gl_pathv[index] else { return nil }
            return URL(fileURLWithFileSystemRepresentation: item, isDirectory: false, relativeTo: nil)
        }.sorted { $0.path < $1.path }
    }
}
