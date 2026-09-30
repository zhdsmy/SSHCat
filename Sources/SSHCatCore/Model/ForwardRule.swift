import Foundation

public enum ForwardKind: String, Codable, Sendable, CaseIterable, Equatable {
    case local
    case remote
    case dynamic

    public var label: String {
        switch self {
        case .local: return "本地"
        case .remote: return "远程"
        case .dynamic: return "动态"
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
        case .emptyName: return "名称不能为空"
        case .invalidHost: return "主机不能为空，不能含空白、@ 或冒号，也不能以 - 开头"
        case .invalidUser: return "用户名不能含空白或 @，也不能以 - 开头"
        case .invalidPort: return "端口应为 1–65535"
        case .invalidIdentity: return "密钥必须是绝对路径，不能含换行"
        case .noForwards: return "至少需要一条转发"
        case .invalidBind(let s): return "绑定地址无效：\(s)"
        case .invalidTarget(let s): return "目标地址无效：\(s)"
        case .invalidForwardPort(let s): return "转发端口无效：\(s)（应为 1–65535）"
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
        case .local, .dynamic: return "\(bindAddress):\(bindPort)"
        case .remote: return nil
        }
    }

    public var summary: String {
        switch kind {
        case .local: return "\(bindAddress):\(bindPort) → \(targetHost):\(targetPort)"
        case .remote: return "远端 \(bindAddress):\(bindPort) ← \(targetHost):\(targetPort)"
        case .dynamic: return "SOCKS \(bindAddress):\(bindPort)"
        }
    }

    /// Remote bind outside loopback only works when sshd has GatewayPorts enabled.
    public var needsGatewayPorts: Bool {
        kind == .remote && !Self.loopback.contains(bindAddress)
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
            return [kind.flag, "\(bindAddress):\(bindPort):\(targetHost):\(targetPort)"]
        case .dynamic:
            return [kind.flag, "\(bindAddress):\(bindPort)"]
        }
    }

    /// Whether two local listeners would fight over the same socket. Remote forwards listen on
    /// the server, so they never clash with local ones here.
    public func clashes(with other: PortForward) -> Bool {
        guard localEndpoint != nil, other.localEndpoint != nil, bindPort == other.bindPort else { return false }
        let a = Self.normalized(bindAddress), b = Self.normalized(other.bindAddress)
        return a == b || Self.wildcard.contains(a) || Self.wildcard.contains(b)
    }

    private static func normalized(_ address: String) -> String {
        let s = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return s == "localhost" ? "127.0.0.1" : s
    }

    private static let loopback: Set<String> = ["127.0.0.1", "localhost"]
    private static let wildcard: Set<String> = ["0.0.0.0", "*"]
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
        return user.isEmpty ? host : "\(user)@\(host)"
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
        guard let args = try? arguments() else { return "配置还不完整，无法生成命令" }
        return ShellQuote.join([executable] + args)
    }
}

enum SSHToken {
    /// Host alias or hostname. Reject `@` so user and host are not both baked into one field,
    /// and `:` so the value cannot be read as a port. Reject leading `-` so it cannot be an option.
    static func isHost(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return !s.isEmpty && isPlain(s) && !s.contains("@") && !s.contains(":")
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

    /// Bind or target host. IPv6 is rejected: a colon would make `-L a:b:c:d` ambiguous.
    static func isAddress(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return !s.isEmpty && isPlain(s) && !s.contains(":") && !s.contains("@")
    }

    private static func isPlain(_ s: String) -> Bool {
        !s.hasPrefix("-") && !s.contains(where: { $0.isWhitespace })
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
            return "主机指纹未知或已变化。先在终端里执行一次 ssh 连接这台主机，确认指纹后再打开规则。App 不会替你确认。"
        }
        if text.contains("permission denied") {
            return "认证失败。检查密钥路径，或确认 ssh-agent 里有对应的密钥。App 不会弹出密码框。"
        }
        if text.contains("address already in use") {
            return "本机端口已被占用。换一个绑定端口，或先停掉占用它的程序。"
        }
        if text.contains("could not resolve hostname") {
            return "解析不到主机名。检查主机名，或确认它在 ~/.ssh/config 里。"
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
