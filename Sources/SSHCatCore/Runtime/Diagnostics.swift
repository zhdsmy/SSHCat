import Foundation

/// Builds a shareable report for one rule. The home directory is shortened to `~` so key paths
/// don't reveal the account name.
public enum Diagnostics {
    public static func report(
        appVersion: String,
        sshVersion: String?,
        rule: ForwardRule,
        commandLine: String,
        state: String,
        log: [String],
        date: Date = Date(),
        home: String = NSHomeDirectory(),
        identityAgent: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        var lines = [
            L10n.core("diagnostics.title"),
            L10n.core("diagnostics.time", ISO8601DateFormatter().string(from: date)),
            L10n.core("diagnostics.app", appVersion),
            L10n.core("diagnostics.ssh", sshVersion ?? L10n.core("diagnostics.unknown")),
            L10n.core("diagnostics.os", ProcessInfo.processInfo.operatingSystemVersionString),
            L10n.core("diagnostics.rule", rule.name),
            L10n.core("diagnostics.state", state),
            L10n.core("diagnostics.command", commandLine),
            L10n.core("diagnostics.agent_override", identityAgent ?? L10n.core("diagnostics.agent_inherited")),
            L10n.core("diagnostics.agent_environment", environment["SSH_AUTH_SOCK"].flatMap { path in
                path.isEmpty ? nil : L10n.core("diagnostics.agent_socket", path,
                                             FileManager.default.fileExists(atPath: path) ? L10n.core("diagnostics.present") : L10n.core("diagnostics.missing"))
            } ?? L10n.core("diagnostics.unset")),
            "",
            L10n.core("diagnostics.recent_log"),
        ]
        lines.append(contentsOf: log.suffix(80))
        let text = lines.joined(separator: "\n")
        return home.count > 1 ? text.replacingOccurrences(of: home, with: "~") : text
    }
}
