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
        home: String = NSHomeDirectory()
    ) -> String {
        var lines = [
            "SSHCat 诊断信息",
            "时间：\(ISO8601DateFormatter().string(from: date))",
            "App：\(appVersion)",
            "ssh：\(sshVersion ?? "未知")",
            "macOS：\(ProcessInfo.processInfo.operatingSystemVersionString)",
            "规则：\(rule.name)",
            "状态：\(state)",
            "命令：\(commandLine)",
            "",
            "最近日志：",
        ]
        lines.append(contentsOf: log.suffix(80))
        let text = lines.joined(separator: "\n")
        return home.count > 1 ? text.replacingOccurrences(of: home, with: "~") : text
    }
}
