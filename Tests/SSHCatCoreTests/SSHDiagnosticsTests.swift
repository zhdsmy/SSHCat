import Foundation
import Testing
@testable import SSHCatCore

@Suite struct SSHDiagnosticsTests {
    @Test func reverseSOCKSIsExplicitAndRoundTripsWithOldKinds() throws {
        let forward = PortForward(kind: .remoteDynamic, bindAddress: "::1", bindPort: 1080, targetHost: "", targetPort: 0)
        #expect(try forward.arguments() == ["-R", "[::1]:1080"])
        #expect(forward.localEndpoint == nil)
        #expect(!forward.needsGatewayPorts)
        #expect(PortForward(kind: .remoteDynamic, bindAddress: "0.0.0.0").needsGatewayPorts)
        let rule = ForwardRule(name: "proxy", host: "devbox", forwards: [PortForward(), forward])
        #expect(try ForwardStore.decode(ForwardStore.encode([rule])) == [rule])
        var draft = RuleDraft(rule: rule)
        draft.ports[forward.id]?.target = "invalid"
        #expect(draft.issues.isEmpty)
        #expect(throws: ForwardIssue.self) {
            try PortForward(kind: .remote, targetHost: "", targetPort: 0).validate()
        }
        let old = Data(#"{"version":1,"rules":[{"name":"old","host":"devbox","forwards":[{"kind":"local"},{"kind":"remote"},{"kind":"dynamic"}]}]}"#.utf8)
        #expect(try ForwardStore.decode(old)[0].forwards.map(\.kind) == [.local, .remote, .dynamic])
    }

    @Test func capabilitiesHaveSeparateVersionBoundaries() {
        #expect(!SSHCapabilities(version: "OpenSSH_7.5p1").supportsReverseSOCKS)
        #expect(SSHCapabilities(version: "OpenSSH_7.6p1, LibreSSL").supportsReverseSOCKS)
        #expect(!SSHCapabilities(version: "OpenSSH_8.4p1").supportsPermitRemoteOpen)
        #expect(SSHCapabilities(version: "OpenSSH_8.5p1").supportsPermitRemoteOpen)
        #expect(SSHCapabilities(version: "OpenSSH_10.3p1").supportsPermitRemoteOpen)
        #expect(!SSHCapabilities(version: "custom SSH").supportsReverseSOCKS)
        #expect(!SSHCapabilities(version: nil).supportsReverseSOCKS)
    }

    @Test func failuresUseFullContextAndKeepRemoteBindRetryable() {
        #expect(SSHFailure.classify(["WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!", "Host key verification failed."]) == .hostKeyChanged)
        #expect(SSHFailure.classify(["No ED25519 host key is known for devbox", "Host key verification failed."]) == .hostKeyUnknown)
        #expect(SSHFailure.classify(["Too many authentication failures", "Permission denied"]) == .tooManyKeys)
        #expect(SSHFailure.isPermanent(["Too many authentication failures"]))
        #expect(!SSHFailure.isPermanent(["Address already in use", "remote port forwarding failed for listen port 9000"]))
        #expect(SSHFailure.classify(["connect to host devbox port 22: Connection timed out"]) == .timedOut)
        #expect(SSHFailure.offendingKnownHostsFile(in: ["Offending ED25519 key in /Users/me/My SSH/known_hosts:4"]) == "/Users/me/My SSH/known_hosts")
    }

    @Test func forwardLogsOnlyAttributeUnambiguousRemoteTargets() {
        let local = PortForward()
        let remote = PortForward(kind: .remote, targetHost: "localhost", targetPort: 3000)
        let localLine = "channel 2: open failed: connect failed: Connection refused"
        let remoteLine = "connect_to localhost port 3000: failed."
        #expect(SSHForwardFailure.parse(localLine, forwards: [local])?.forwardID == nil)
        #expect(SSHForwardFailure.parse(localLine, forwards: [local])?.reason == .refused)
        #expect(SSHForwardFailure.parse(remoteLine, forwards: [local, remote])?.forwardID == remote.id)
        #expect(SSHForwardFailure.parse(remoteLine, forwards: [remote, PortForward(kind: .remote, targetHost: "localhost", targetPort: 3000)])?.forwardID == nil)
        #expect(SSHForwardFailure.parse("connect to host devbox port 22: Connection refused", forwards: [local]) == nil)
    }

    @Test func configurationPreservesRepeatedKeysAndFindsInheritedForwards() throws {
        let config = SSHConfiguration(output: """
        user app
        hostname devbox.example
        port 2222
        identityfile /Users/me/My Keys/key
        identityfile ~/.ssh/id_ed25519
        localforward 8080 127.0.0.1:8080
        localforward 9090 127.0.0.1:9090
        """)
        let rule = ForwardRule(name: "web", host: "alias", forwards: [PortForward()])
        #expect(config.values["identityfile"] == ["/Users/me/My Keys/key", "~/.ssh/id_ed25519"])
        #expect(config.hasAdditionalForwards(comparedTo: rule))
        let file = "/Users/me/My SSH/known_hosts"
        #expect(config.hostKeyRemovalCommand(knownHostsFile: file) == "ssh-keygen -f '/Users/me/My SSH/known_hosts' -R '[devbox.example]:2222'")
        let alias = SSHConfiguration(output: "hostname devbox.example\nport 2222\nhostkeyalias trusted-alias\n")
        #expect(alias.hostKeyRemovalCommand(knownHostsFile: file)?.hasSuffix("-R trusted-alias") == true)
        #expect(config.hostKeyRemovalCommand(knownHostsFile: "-bad") == nil)
        let jump = SSHConfiguration(output: "hostname devbox.example\nport 22\nproxyjump gateway\n")
        #expect(jump.hostKeyRemovalCommand(knownHostsFile: file) == nil)
        let suggested = #"  ssh-keygen -f "/Users/me/My SSH/known_hosts" -R "[gateway.example]:2222""#
        #expect(SSHFailure.hostKeyRemovalCommand(in: [suggested]) == "ssh-keygen -f '/Users/me/My SSH/known_hosts' -R '[gateway.example]:2222'")
        #expect(SSHFailure.hostKeyRemovalCommand(in: [suggested + "; echo bad"]) == nil)
    }

    @Test func agentSettingIsOptionalValidatedAndSharedByCommands() throws {
        let suite = "SSHCat-agent-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.identityAgent == nil)
        settings.identityAgent = " /Users/me/Agent Sockets/agent.sock "
        #expect(settings.identityAgent == "/Users/me/Agent Sockets/agent.sock")
        let rule = ForwardRule(name: "web", host: "devbox", forwards: [PortForward()])
        #expect(try rule.arguments(identityAgent: settings.identityAgent).contains(#"IdentityAgent="/Users/me/Agent Sockets/agent.sock""#))
        #expect(try rule.firstConnectionCommand(executable: "ssh", identityAgent: settings.identityAgent).contains("IdentityAgent="))
        for value in ["relative.sock", "-bad", "/tmp/agent\n-o ProxyCommand=bad", "/tmp/agent\0"] {
            #expect(throws: ForwardIssue.invalidAgent) { try rule.arguments(identityAgent: value) }
        }
        settings.identityAgent = ""
        #expect(defaults.object(forKey: AppSettings.Key.identityAgent) == nil)
        #expect(try rule.arguments() == rule.arguments(identityAgent: nil))
        let report = Diagnostics.report(appVersion: "test", sshVersion: nil, rule: rule, commandLine: "ssh", state: "test", log: [],
                                        home: "/Users/me", identityAgent: "/Users/me/agent.sock", environment: ["SSH_AUTH_SOCK": "/Users/me/missing.sock"])
        #expect(report.contains("SSH_AUTH_SOCK"))
        #expect(report.contains("~/agent.sock"))
        #expect(!report.contains("/Users/me"))
    }

    @Test func boundedCaptureHandlesLargeOutputErrorsTimeoutAndCancellation() async throws {
        let sh = URL(fileURLWithPath: "/bin/sh")
        let text = try await SSHCommand.output(executable: sh, arguments: ["-c", "head -c 131072 /dev/zero | tr '\\0' a"])
        #expect(text.utf8.count == 131072)
        await #expect(throws: SSHConfigurationError.commandFailed("bad\n")) {
            try await SSHCommand.output(executable: sh, arguments: ["-c", "echo bad >&2; exit 2"])
        }
        await #expect(throws: SSHConfigurationError.timeout) {
            try await SSHCommand.output(executable: sh, arguments: ["-c", "exec sleep 10"], timeout: 0.1)
        }
        await #expect(throws: SSHConfigurationError.tooLarge) {
            try await SSHCommand.output(executable: sh, arguments: ["-c", "head -c 4096 /dev/zero"], maximumBytes: 1024)
        }
        let job = Task { try await SSHCommand.output(executable: sh, arguments: ["-c", "exec sleep 10"]) }
        try await Task.sleep(nanoseconds: 50_000_000)
        job.cancel()
        await #expect(throws: CancellationError.self) { try await job.value }
    }

    @Test func reverseSOCKSLaunchChecksTheSelectedClient() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SSHCat-version-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("ssh")
        func version(_ value: String) throws {
            try Data("#!/bin/sh\n[ \"$1\" = '-V' ] || exit 9\necho '\(value)' >&2\n".utf8).write(to: fake)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        }
        try version("OpenSSH_7.5p1")
        let locator = BinaryLocator(customPath: { fake.path }, environmentPATH: nil)
        let config = RunnerConfig.live(locator: locator, identityAgent: { "/tmp/fake agent.sock" })
        let rule = ForwardRule(name: "proxy", host: "devbox", forwards: [PortForward(kind: .remoteDynamic, bindPort: 1080)])
        await #expect(throws: LaunchError.reverseSOCKSUnsupported) { try await config.launch(rule) }
        try version("OpenSSH_7.6p1")
        let launch = try await config.launch(rule)
        #expect(launch.executable == fake)
        #expect(launch.arguments == (try rule.arguments(identityAgent: "/tmp/fake agent.sock")))
    }

    @Test func previewUsesRuleArgumentsWithoutAConnection() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SSHCat-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("ssh")
        let script = """
        #!/bin/sh
        [ "$1" = '-G' ] || exit 9
        printf 'user app\nhostname devbox.example\nport 2222\n'
        for argument in "$@"; do printf 'argument %s\n' "$argument"; done
        """
        try Data(script.utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        let rule = ForwardRule(name: "web", host: "devbox", port: 2222, forwards: [PortForward()])
        let preview = try await SSHConfiguration.inspect(executable: fake, rule: rule, identityAgent: "/tmp/fake agent.sock")
        let arguments = try #require(preview.values["argument"])
        #expect(arguments == ["-G"] + (try rule.arguments(identityAgent: "/tmp/fake agent.sock")))
    }
}
