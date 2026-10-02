import Foundation

public enum RuleField: Hashable, Sendable {
    case name, host, user, sshPort, identity, forwards
    case bindAddress(UUID), bindPort(UUID), targetHost(UUID), targetPort(UUID)
}

/// Text stays in the draft, including empty or invalid ports, until validation succeeds.
public struct RuleDraft: Equatable, Sendable {
    public struct Ports: Equatable, Sendable {
        public var bind: String
        public var target: String
    }
    public var rule: ForwardRule
    public var portText: String
    public var ports: [UUID: Ports]

    public init(rule: ForwardRule, portText: String? = nil) {
        self.rule = rule
        self.portText = portText ?? rule.port.map(String.init) ?? ""
        ports = Dictionary(rule.forwards.map { ($0.id, Ports(bind: String($0.bindPort), target: String($0.targetPort))) },
                           uniquingKeysWith: { first, _ in first })
    }

    public var issues: [(field: RuleField, issue: ForwardIssue)] {
        let value = normalized
        var result: [(RuleField, ForwardIssue)] = []
        if value.name.isEmpty { result.append((.name, .emptyName)) }
        if !SSHToken.isHost(value.host) { result.append((.host, .invalidHost)) }
        if !SSHToken.isUser(value.user) { result.append((.user, .invalidUser)) }
        if !trim(portText).isEmpty && !validPort(portText) { result.append((.sshPort, .invalidPort)) }
        if !SSHToken.isIdentity(value.identityFile) { result.append((.identity, .invalidIdentity)) }
        if value.forwards.isEmpty { result.append((.forwards, .noForwards)) }
        for forward in value.forwards {
            let text = portDraft(forward)
            if !SSHToken.isAddress(forward.bindAddress) { result.append((.bindAddress(forward.id), .invalidBind(forward.bindAddress))) }
            if !validPort(text.bind) { result.append((.bindPort(forward.id), .invalidPort)) }
            if forward.kind != .dynamic {
                if !SSHToken.isAddress(forward.targetHost) { result.append((.targetHost(forward.id), .invalidTarget(forward.targetHost))) }
                if !validPort(text.target) { result.append((.targetPort(forward.id), .invalidPort)) }
            }
        }
        return result
    }

    public func issue(for field: RuleField) -> ForwardIssue? { issues.first { $0.field == field }?.issue }

    public func validated() throws -> ForwardRule {
        if let issue = issues.first?.issue { throw issue }
        return normalized
    }

    public func isDirty(comparedTo saved: ForwardRule) -> Bool {
        if let value = try? validated(), let baseline = try? RuleDraft(rule: saved).validated() {
            return value != baseline
        }
        return self != RuleDraft(rule: saved)
    }

    public func portDraft(_ forward: PortForward) -> Ports {
        ports[forward.id] ?? Ports(bind: String(forward.bindPort), target: String(forward.targetPort))
    }

    private var normalized: ForwardRule {
        var value = rule
        value.name = trim(value.name)
        value.host = trim(value.host)
        value.user = trim(value.user)
        value.identityFile = trim(value.identityFile)
        value.port = Int(trim(portText))
        for index in value.forwards.indices {
            let text = portDraft(value.forwards[index])
            value.forwards[index].bindAddress = trim(value.forwards[index].bindAddress)
            value.forwards[index].targetHost = trim(value.forwards[index].targetHost)
            value.forwards[index].bindPort = Int(trim(text.bind)) ?? 0
            value.forwards[index].targetPort = Int(trim(text.target)) ?? 0
        }
        return value
    }

    private func trim(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private func validPort(_ text: String) -> Bool {
        Int(trim(text)).map(SSHToken.isPort) ?? false
    }
}

extension ForwardRule {
    /// Copied for a human to run in Terminal; the app never executes this interactive command.
    public func firstConnectionCommand(executable: String) throws -> String {
        guard SSHToken.isHost(host) else { throw ForwardIssue.invalidHost }
        guard SSHToken.isUser(user) else { throw ForwardIssue.invalidUser }
        if let port, !SSHToken.isPort(port) { throw ForwardIssue.invalidPort }
        guard SSHToken.isIdentity(identityFile) else { throw ForwardIssue.invalidIdentity }
        var args = [executable, "-o", "BatchMode=no", "-o", "StrictHostKeyChecking=ask",
                    "-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "ClearAllForwardings=yes"]
        if let port { args += ["-p", String(port)] }
        let identity = identityFile.trimmingCharacters(in: .whitespacesAndNewlines)
        if !identity.isEmpty { args += ["-i", identity, "-o", "IdentitiesOnly=yes"] }
        return ShellQuote.join(args + [destination])
    }
}
