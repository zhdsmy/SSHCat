import Foundation
import Darwin

public enum ForwardKind: String, Codable, Sendable, CaseIterable, Equatable {
    case local
    case remote
    case dynamic

    public var label: String {
        switch self {
        case .local: return L10n.core("forward.kind.local")
        case .remote: return L10n.core("forward.kind.remote")
        case .dynamic: return L10n.core("forward.kind.dynamic")
        }
    }

    public var defaultName: String {
        switch self {
        case .local: return L10n.core("forward.default.local")
        case .remote: return L10n.core("forward.default.remote")
        case .dynamic: return L10n.core("forward.default.dynamic")
        }
    }

    /// ssh flag for this forward. Dynamic forwards have no remote target.
    public var flag: String {
        switch self {
        case .local: return "-L"
        case .remote: return "-R"
        case .dynamic: return "-D"
        }
    }
}

public enum ForwardIssue: Error, Equatable, Sendable, LocalizedError {
    case emptyName
    case invalidHost
    case invalidUser
    case invalidPort
    case invalidIdentity
    case noForwards
    case invalidBind(String)
    case invalidTarget(String)
    case invalidForwardPort(String)

    public var errorDescription: String? {
        switch self {
        case .emptyName: return L10n.core("validation.name_empty")
        case .invalidHost: return L10n.core("validation.host_invalid")
        case .invalidUser: return L10n.core("validation.user_invalid")
        case .invalidPort: return L10n.core("validation.port_invalid")
        case .invalidIdentity: return L10n.core("validation.identity_invalid")
        case .noForwards: return L10n.core("validation.forwards_empty")
        case .invalidBind(let s): return L10n.core("validation.bind_invalid", s)
        case .invalidTarget(let s): return L10n.core("validation.target_invalid", s)
        case .invalidForwardPort(let s): return L10n.core("validation.forward_port_invalid", s)
        }
    }
}

public struct PortForward: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var kind: ForwardKind
    /// Address ssh binds. For remote forwards this address is on the server.
    public var bindAddress: String
    public var bindPort: Int
    /// Ignored for dynamic forwards.
    public var targetHost: String
    public var targetPort: Int

    public init(
        id: UUID = UUID(),
        kind: ForwardKind = .local,
        bindAddress: String = "127.0.0.1",
        bindPort: Int = 8080,
        targetHost: String = "127.0.0.1",
        targetPort: Int = 8080
    ) {
        self.id = id
        self.kind = kind
        self.bindAddress = bindAddress
        self.bindPort = bindPort
        self.targetHost = targetHost
        self.targetPort = targetPort
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decodeIfPresent(ForwardKind.self, forKey: .kind) ?? .local
        bindAddress = try c.decodeIfPresent(String.self, forKey: .bindAddress) ?? "127.0.0.1"
        bindPort = try c.decodeIfPresent(Int.self, forKey: .bindPort) ?? 8080
        targetHost = try c.decodeIfPresent(String.self, forKey: .targetHost) ?? "127.0.0.1"
        targetPort = try c.decodeIfPresent(Int.self, forKey: .targetPort) ?? 8080
    }

    /// Local or dynamic listen endpoint the user can copy. Remote forwards listen on the server.
    public var localEndpoint: String? {
        switch kind {
        case .local, .dynamic: return "\(SSHToken.forwardAddress(bindAddress)):\(bindPort)"
        case .remote: return nil
        }
    }

    public var summary: String {
        switch kind {
        case .local:
            return "\(SSHToken.forwardAddress(bindAddress)):\(bindPort) → \(SSHToken.forwardAddress(targetHost)):\(targetPort)"
        case .remote:
            return L10n.core("forward.remote_summary", SSHToken.forwardAddress(bindAddress), bindPort,
                             SSHToken.forwardAddress(targetHost), targetPort)
        case .dynamic: return "SOCKS \(SSHToken.forwardAddress(bindAddress)):\(bindPort)"
        }
    }

    /// Remote bind outside loopback only works when sshd has GatewayPorts enabled.
    public var needsGatewayPorts: Bool {
        kind == .remote && !SSHToken.isLoopback(bindAddress)
    }

    public func validate() throws {
        if !SSHToken.isAddress(bindAddress) { throw ForwardIssue.invalidBind(bindAddress) }
        if !SSHToken.isPort(bindPort) { throw ForwardIssue.invalidForwardPort(String(bindPort)) }
        if kind != .dynamic {
            if !SSHToken.isAddress(targetHost) { throw ForwardIssue.invalidTarget(targetHost) }
            if !SSHToken.isPort(targetPort) { throw ForwardIssue.invalidForwardPort(String(targetPort)) }
        }
    }

    /// argv pair, e.g. `-L`, `127.0.0.1:8080:127.0.0.1:8080`.
    public func arguments() throws -> [String] {
        try validate()
        switch kind {
        case .local, .remote:
            return [kind.flag, "\(SSHToken.forwardAddress(bindAddress)):\(bindPort):\(SSHToken.forwardAddress(targetHost)):\(targetPort)"]
        case .dynamic:
            return [kind.flag, "\(SSHToken.forwardAddress(bindAddress)):\(bindPort)"]
        }
    }

    /// Whether two local listeners would fight over the same socket. Remote forwards listen on
    /// the server, so they never clash with local ones here.
    public func clashes(with other: PortForward) -> Bool {
        guard localEndpoint != nil, other.localEndpoint != nil, bindPort == other.bindPort else { return false }
        return SSHToken.bindAddressesClash(bindAddress, other.bindAddress)
    }
}

/// One long-running `ssh -N`: a destination plus any mix of `-L`, `-R`, and `-D`.
public struct ForwardRule: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    /// Empty lets ssh config's `User` apply.
    public var user: String
    public var host: String
    /// Nil lets ssh config's `Port` apply.
    public var port: Int?
    /// Empty lets ssh config and the agent choose a key. An absolute path is passed as `-i`.
    public var identityFile: String
    public var forwards: [PortForward]
    public var autoRestart: Bool
    public var autoStart: Bool

    public init(
        id: UUID = UUID(),
        name: String = "",
        user: String = "",
        host: String = "",
        port: Int? = nil,
        identityFile: String = "",
        forwards: [PortForward] = [],
        autoRestart: Bool = true,
        autoStart: Bool = false
    ) {
        self.id = id
        self.name = name
        self.user = user
        self.host = host
        self.port = port
        self.identityFile = identityFile
        self.forwards = forwards
        self.autoRestart = autoRestart
        self.autoStart = autoStart
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        user = try c.decodeIfPresent(String.self, forKey: .user) ?? ""
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        identityFile = try c.decodeIfPresent(String.self, forKey: .identityFile) ?? ""
        forwards = try c.decodeIfPresent([PortForward].self, forKey: .forwards) ?? []
        autoRestart = try c.decodeIfPresent(Bool.self, forKey: .autoRestart) ?? true
        autoStart = try c.decodeIfPresent(Bool.self, forKey: .autoStart) ?? false
    }

    public var destination: String {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = user.trimmingCharacters(in: .whitespacesAndNewlines)
        let destinationHost = SSHToken.sshDestinationHost(host)
        return user.isEmpty ? destinationHost : "\(user)@\(destinationHost)"
    }

    /// A copy must not inherit launch-on-open or any IDs used by the list and editor.
    public func duplicate() -> ForwardRule {
        var copy = self
        copy.id = UUID()
        copy.name = L10n.core("rule.copy_name", name)
        copy.autoStart = false
        copy.forwards = forwards.map { forward in
            var copy = forward
            copy.id = UUID()
            return copy
        }
        return copy
    }

    public func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || ([name, destination] + forwards.map(\.summary))
            .contains { $0.localizedStandardContains(query) }
    }

    public func validate() throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { throw ForwardIssue.emptyName }
        if !SSHToken.isHost(host) { throw ForwardIssue.invalidHost }
        if !SSHToken.isUser(user) { throw ForwardIssue.invalidUser }
        if let port, !SSHToken.isPort(port) { throw ForwardIssue.invalidPort }
        if !SSHToken.isIdentity(identityFile) { throw ForwardIssue.invalidIdentity }
        if forwards.isEmpty { throw ForwardIssue.noForwards }
        for forward in forwards { try forward.validate() }
    }

    /// argv after the ssh executable. Fixed options keep the session owned by the supervisor:
    /// BatchMode avoids a password prompt with no tty, ControlMaster=no so stopping the rule
    /// actually stops the forward, ServerAlive so a dead link exits and can be restarted,
    /// ExitOnForwardFailure so a bind error is not silent, ConnectTimeout so an unreachable host
    /// fails in seconds rather than the TCP timeout. VERBOSE makes ssh print `Authenticated to …`,
    /// the runner's signal that the session is actually up (see `SSHLog`).
    public func arguments() throws -> [String] {
        try validate()
        var args = [
            "-N",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "BatchMode=yes",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "ConnectTimeout=10",
            "-o", "LogLevel=VERBOSE",
        ]
        if let port {
            args.append(contentsOf: ["-p", String(port)])
        }
        let identity = identityFile.trimmingCharacters(in: .whitespacesAndNewlines)
        if !identity.isEmpty {
            // Without IdentitiesOnly, ssh may still offer agent keys and never use -i.
            args.append(contentsOf: ["-i", identity, "-o", "IdentitiesOnly=yes"])
        }
        for forward in forwards {
            args.append(contentsOf: try forward.arguments())
        }
        args.append(destination)
        return args
    }

    public func commandLine(executable: String) -> String {
        guard let args = try? arguments() else { return L10n.core("rule.command_unavailable") }
        return ShellQuote.join([executable] + args)
    }
}

enum SSHToken {
    /// Host aliases cannot contain a port separator. Colons are accepted only in valid IPv6 literals.
    static func isHost(_ raw: String) -> Bool {
        guard !containsControl(raw) else { return false }
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if isIPv6(s) { return true }
        return !s.isEmpty && isPlain(s) && !s.contains("@") && !s.contains(":") &&
            !s.contains("%") && !s.contains("[") && !s.contains("]")
    }

    /// Empty is valid: ssh config supplies User.
    static func isUser(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty || (isPlain(s) && !s.contains("@"))
    }

    static func isPort(_ port: Int) -> Bool {
        (1...65535).contains(port)
    }

    /// Empty is valid. A set path must be absolute so a relative path is not resolved against
    /// the app's working directory, and must not contain a newline.
    static func isIdentity(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return true }
        if s.contains("\n") || s.contains("\r") || s.hasPrefix("-") { return false }
        return s.hasPrefix("/")
    }

    /// Bind or target host. IPv6 is bracketed only when serialized into ssh's forwarding syntax.
    static func isAddress(_ raw: String) -> Bool {
        guard !containsControl(raw) else { return false }
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if isIPv6(s) { return true }
        return !s.isEmpty && isPlain(s) && !s.contains("@") && !s.contains(":") &&
            !s.contains("%") && !s.contains("[") && !s.contains("]")
    }

    static func forwardAddress(_ raw: String) -> String {
        guard let address = ipv6Literal(raw) else { return raw.trimmingCharacters(in: .whitespacesAndNewlines) }
        return "[\(address)]"
    }

    static func sshDestinationHost(_ raw: String) -> String {
        ipv6Literal(raw) ?? raw
    }

    static func isLoopback(_ raw: String) -> Bool {
        bindIdentity(raw).isLoopback
    }

    static func bindAddressesClash(_ lhs: String, _ rhs: String) -> Bool {
        let a = bindIdentity(lhs), b = bindIdentity(rhs)
        if a == .any || b == .any || a == b { return true }

        if a == .localhost { return b.isLocalhostListener || b.isWildcard }
        if b == .localhost { return a.isLocalhostListener || a.isWildcard }

        switch (a, b) {
        case (.ipv4(let left), .ipv4(let right)):
            return left == right || left.allSatisfy { $0 == 0 } || right.allSatisfy { $0 == 0 }
        case (.ipv6(let left, let leftScope), .ipv6(let right, let rightScope)):
            let sameScope = leftScope == rightScope || leftScope == nil || rightScope == nil
            let leftWildcard = left.allSatisfy { $0 == 0 }
            let rightWildcard = right.allSatisfy { $0 == 0 }
            return left == right && sameScope || leftWildcard || rightWildcard
        case (.ipv4(let address), .name), (.name, .ipv4(let address)):
            return address.allSatisfy { $0 == 0 }
        case (.ipv6(let address, _), .name), (.name, .ipv6(let address, _)):
            return address.allSatisfy { $0 == 0 }
        default:
            return false
        }
    }

    private enum BindIdentity: Equatable {
        case any
        case localhost
        case ipv4([UInt8])
        case ipv6([UInt8], String?)
        case name(String)

        var isLoopback: Bool {
            switch self {
            case .localhost: return true
            case .ipv4(let bytes): return bytes.first == 127
            case .ipv6(let bytes, _): return bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
            default: return false
            }
        }

        /// SSH's localhost listener binds 127.0.0.1 and ::1, not the entire 127/8 range.
        var isLocalhostListener: Bool {
            if case .ipv4(let bytes) = self { return bytes == [127, 0, 0, 1] }
            return isLoopback
        }

        var isWildcard: Bool {
            switch self {
            case .any: return true
            case .ipv4(let bytes), .ipv6(let bytes, _): return bytes.allSatisfy { $0 == 0 }
            default: return false
            }
        }
    }

    private static func bindIdentity(_ raw: String) -> BindIdentity {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value == "*" { return .any }
        if value == "localhost" { return .localhost }
        if let literal = ipv6Literal(value), let parsed = parsedIPv6(literal) {
            return .ipv6(parsed.bytes, parsed.scope)
        }
        if let bytes = parsedIPv4(value) { return .ipv4(bytes) }
        return .name(value)
    }

    private static func isIPv6(_ raw: String) -> Bool {
        ipv6Literal(raw) != nil
    }

    private static func ipv6Literal(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let literal: String
        if value.hasPrefix("[") || value.hasSuffix("]") {
            guard value.hasPrefix("["), value.hasSuffix("]") else { return nil }
            literal = String(value.dropFirst().dropLast())
        } else {
            guard !value.contains("[") && !value.contains("]") else { return nil }
            literal = value
        }
        return parsedIPv6(literal) == nil ? nil : literal
    }

    private static func parsedIPv6(_ literal: String) -> (bytes: [UInt8], scope: String?)? {
        let parts = literal.split(separator: "%", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else { return nil }
        let address = String(parts[0])
        let scope = parts.count == 2 ? String(parts[1]) : nil
        if let scope {
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
            let leading = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
            guard let first = scope.unicodeScalars.first, leading.contains(first),
                  scope.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        }
        var parsed = in6_addr()
        guard address.withCString({ inet_pton(AF_INET6, $0, &parsed) }) == 1 else { return nil }
        let bytes = withUnsafeBytes(of: &parsed) { Array($0) }
        return (bytes, scope)
    }

    private static func parsedIPv4(_ literal: String) -> [UInt8]? {
        var parsed = in_addr()
        guard literal.withCString({ inet_pton(AF_INET, $0, &parsed) }) == 1 else { return nil }
        return withUnsafeBytes(of: &parsed) { Array($0) }
    }

    private static func isPlain(_ s: String) -> Bool {
        !s.hasPrefix("-") && !s.contains(where: { $0.isWhitespace }) && !containsControl(s)
    }

    private static func containsControl(_ value: String) -> Bool {
        let controls = CharacterSet.controlCharacters
        return value.unicodeScalars.contains { controls.contains($0) }
    }
}

/// Reads ssh's `LogLevel=VERBOSE` stderr.
public enum SSHLog {
    /// Printed once authentication succeeds (also `… (via proxy) …` behind ProxyJump).
    public static func isAuthenticated(_ line: String) -> Bool {
        line.hasPrefix("Authenticated to ")
    }

    /// Progress chatter from VERBOSE, never the reason a session ended.
    public static func isInformational(_ line: String) -> Bool {
        let prefixes = [
            "Authenticated to ",
            "Transferred: ",
            "Bytes per second: ",
            "Local connections to ",
            "Remote connections from ",
            "Local forwarding listening on ",
            "Warning: Permanently added ",
        ]
        return prefixes.contains { line.hasPrefix($0) }
    }
}

/// stderr lines that will not start working just by launching ssh again.
public enum SSHFailure {
    /// What the user can do about a failure ssh reports tersely.
    public static func hint(for reason: String) -> String? {
        let text = reason.lowercased()
        if text.contains("host key verification failed") {
            return L10n.core("failure.host_key_hint")
        }
        if text.contains("permission denied") {
            return L10n.core("failure.authentication_hint")
        }
        if text.contains("address already in use") {
            return L10n.core("failure.port_hint")
        }
        if text.contains("could not resolve hostname") {
            return L10n.core("failure.host_hint")
        }
        return nil
    }

    public static func isPermanent(_ lines: [String]) -> Bool {
        let blob = lines.joined(separator: "\n").lowercased()
        let needles = [
            "address already in use",
            "cannot listen to port",
            "permission denied",
            "bad local forwarding specification",
            "bad remote forwarding specification",
            "bad dynamic forwarding specification",
            "no such file or directory",
            "host key verification failed",
        ]
        return needles.contains { blob.contains($0) }
    }
}
