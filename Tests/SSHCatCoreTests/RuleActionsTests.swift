import Testing
@testable import SSHCatCore

@Suite struct RuleActionsTests {
    @Test func duplicatePreservesConfigurationWithoutAutomaticStartup() throws {
        let rule = ForwardRule(name: "Web", user: "app", host: "devbox", port: 2222,
                               identityFile: "/Users/me/.ssh/id_ed25519",
                               forwards: [PortForward(), PortForward(kind: .dynamic, bindPort: 1080)],
                               autoRestart: false, autoStart: true)
        let copy = rule.duplicate()
        #expect(copy.id != rule.id)
        #expect(copy.name == L10n.core("rule.copy_name", "Web"))
        #expect(!copy.autoStart)
        #expect(!copy.autoRestart)
        #expect(Set(copy.forwards.map(\.id)).isDisjoint(with: rule.forwards.map(\.id)))
        #expect(try copy.arguments() == rule.arguments())
    }

    @Test func searchIncludesNameDestinationAndPorts() {
        let rule = ForwardRule(name: "开发网站", user: "app", host: "devbox", forwards: [PortForward()])
        #expect(rule.matches("网站"))
        #expect(rule.matches(" APP@DEVBOX "))
        #expect(rule.matches("8080"))
        #expect(rule.matches("  "))
        #expect(!rule.matches("1080"))
    }
}
