import Foundation
import Testing
@testable import SSHCatCore

private func sample() -> ForwardRule {
    ForwardRule(
        name: "web",
        user: "app",
        host: "devbox",
        forwards: [PortForward(kind: .local, bindAddress: "127.0.0.1", bindPort: 8080,
                               targetHost: "127.0.0.1", targetPort: 8080)]
    )
}

@Suite struct ModelTests {
    @Test func localForwardArguments() throws {
        let args = try sample().arguments()
        #expect(args == [
            "-N",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "BatchMode=yes",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "ConnectTimeout=10",
            "-o", "LogLevel=VERBOSE",
            "-L", "127.0.0.1:8080:127.0.0.1:8080",
            "app@devbox",
        ])
    }

    @Test func portAndIdentityOverride() throws {
        var rule = sample()
        rule.port = 2222
        rule.identityFile = "/Users/me/.ssh/id_ed25519"
        let args = try rule.arguments()
        #expect(args == [
            "-N",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "BatchMode=yes",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "ConnectTimeout=10",
            "-o", "LogLevel=VERBOSE",
            "-p", "2222",
            "-i", "/Users/me/.ssh/id_ed25519",
            "-o", "IdentitiesOnly=yes",
            "-L", "127.0.0.1:8080:127.0.0.1:8080",
            "app@devbox",
        ])
    }

    @Test func remoteDynamicAndEmptyUser() throws {
        var rule = sample()
        rule.user = ""
        rule.forwards = [
            PortForward(kind: .remote, bindAddress: "127.0.0.1", bindPort: 9000,
                        targetHost: "127.0.0.1", targetPort: 3000),
            PortForward(kind: .dynamic, bindAddress: "127.0.0.1", bindPort: 1080),
        ]
        let args = try rule.arguments()
        #expect(args.contains("-R"))
        #expect(args.contains("127.0.0.1:9000:127.0.0.1:3000"))
        #expect(args.contains("-D"))
        #expect(args.contains("127.0.0.1:1080"))
        #expect(args.last == "devbox")
    }

    @Test func rejectsOptionInjection() {
        var rule = sample()
        rule.host = "-oProxyCommand=oops"
        #expect(throws: ForwardIssue.invalidHost) { try rule.validate() }
        rule = sample()
        rule.user = "app extra"
        #expect(throws: ForwardIssue.invalidUser) { try rule.validate() }
        rule = sample()
        rule.forwards[0].bindAddress = "127.0.0.1:1"
        #expect(throws: ForwardIssue.self) { try rule.validate() }
        rule = sample()
        rule.identityFile = "id_ed25519"
        #expect(throws: ForwardIssue.invalidIdentity) { try rule.validate() }
        rule = sample()
        rule.forwards = []
        #expect(throws: ForwardIssue.noForwards) { try rule.validate() }
    }

    @Test func commandLineQuotesSpaces() throws {
        var rule = sample()
        rule.identityFile = "/Users/me/My Keys/id_ed25519"
        let line = rule.commandLine(executable: "/usr/bin/ssh")
        #expect(line.contains("'/Users/me/My Keys/id_ed25519'"))
        #expect(line.hasPrefix("/usr/bin/ssh -N "))
    }

    @Test func parsesSSHConfigHosts() {
        let text = """
        # Host commented
        Host devbox other
          HostName 10.0.0.8
        Host *.internal
          User app
        Host !skip
        Host "odd"
        """
        #expect(SSHConfigHosts.parse(text) == ["devbox", "other", "odd"])
    }

    @Test func permanentFailures() {
        #expect(SSHFailure.isPermanent(["bind [127.0.0.1]:8080: Address already in use"]))
        #expect(SSHFailure.isPermanent(["app@devbox: Permission denied (publickey)."]))
        #expect(SSHFailure.isPermanent(["Host key verification failed."]))
        #expect(!SSHFailure.isPermanent(["connect to host devbox port 22: Connection refused"]))
    }

    @Test func verboseLogClassification() {
        #expect(SSHLog.isAuthenticated(#"Authenticated to devbox ([10.0.0.1]:22) using "publickey"."#))
        #expect(SSHLog.isAuthenticated(#"Authenticated to devbox (via proxy) using "publickey"."#))
        #expect(!SSHLog.isAuthenticated("app@devbox: Permission denied (publickey)."))
        #expect(SSHLog.isInformational("Transferred: sent 2112, received 2016 bytes, in 45.0 seconds"))
        #expect(SSHLog.isInformational("Local forwarding listening on 127.0.0.1 port 8080."))
        #expect(!SSHLog.isInformational("Timeout, server devbox not responding."))
    }

    @Test func failureHints() {
        #expect(SSHFailure.hint(for: "Host key verification failed.") == L10n.core("failure.host_key_hint"))
        #expect(SSHFailure.hint(for: "app@devbox: Permission denied (publickey).")?.contains("ssh-agent") == true)
        #expect(SSHFailure.hint(for: "connect to host devbox port 22: Connection refused") == L10n.core("failure.refused_hint"))
    }

    @Test func reapsOnlyOrphanedSSH() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SSHCatPIDs-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tracker = PIDTracker(directory: dir)
        tracker.save(["a": 999_991, "b": 999_992])
        var checked: [Int32] = []
        tracker.reapOrphans { pid in checked.append(pid); return false }
        #expect(Set(checked) == [999_991, 999_992])
        #expect(tracker.load().isEmpty)
        // This test process is an ssh-less child of the test runner, not adopted by launchd.
        #expect(!PIDTracker.looksLikeOrphanedSSH(getpid()))
    }

    @Test func diagnosticsShortenHome() {
        var rule = sample()
        rule.identityFile = "/Users/someone/.ssh/id_ed25519"
        let text = Diagnostics.report(appVersion: "0.1.0", sshVersion: "OpenSSH_10.3p1", rule: rule,
                                      commandLine: rule.commandLine(executable: "/usr/bin/ssh"),
                                      state: "运行中", log: ["line"], home: "/Users/someone")
        #expect(text.contains("~/.ssh/id_ed25519"))
        #expect(!text.contains("/Users/someone"))
        #expect(text.hasSuffix("line"))
    }

    @Test func backoffDoublesThenCaps() {
        let p = BackoffPolicy(base: 1, cap: 60)
        #expect((1...8).map { p.delay(forAttempt: $0) } == [1, 2, 4, 8, 16, 32, 60, 60])
        #expect(p.delay(forAttempt: 500) == 60)
    }

    @Test func loadsVersion1File() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SSHCatV1-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ForwardStore(directory: dir)
        // Missing optional keys fall back to defaults instead of failing the whole file.
        let v1 = #"{"version":1,"rules":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"old","host":"devbox","forwards":[{"kind":"dynamic","bindPort":1080}]}]}"#
        try Data(v1.utf8).write(to: store.fileURL)
        let rules = try store.load()
        #expect(rules.count == 1)
        #expect(rules[0].autoRestart)
        #expect(rules[0].forwards[0].kind == .dynamic)
        #expect(rules[0].forwards[0].bindAddress == "127.0.0.1")
    }

    @Test func storeRoundTripAndPermissions() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SSHCatTests-\(UUID().uuidString)", isDirectory: true)
        let store = ForwardStore(directory: dir)
        var rule = sample()
        rule.autoStart = true
        try store.save([rule])
        let loaded = try store.load()
        #expect(loaded == [rule])

        let fileMode = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? NSNumber
        let dirMode = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? NSNumber
        #expect((fileMode?.uint16Value ?? 0) & 0o777 == 0o600)
        #expect((dirMode?.uint16Value ?? 0) & 0o777 == 0o700)

        try Data("not json".utf8).write(to: store.fileURL)
        #expect(throws: ForwardStoreError.self) { try store.load() }
        let leftovers = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        #expect(leftovers.contains { $0.lastPathComponent.hasPrefix("forwards.corrupt-") })
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func locatorPrefersCustomPath() {
        let locator = BinaryLocator(
            customPath: { "/custom/ssh" },
            fallback: "/usr/bin/ssh",
            environmentPATH: "/bin",
            isExecutable: { $0 == "/custom/ssh" || $0 == "/bin/ssh" }
        )
        #expect(locator.locate()?.path == "/custom/ssh")

        let fallback = BinaryLocator(
            customPath: { nil },
            fallback: "/usr/bin/ssh",
            environmentPATH: "/nowhere",
            isExecutable: { $0 == "/usr/bin/ssh" }
        )
        #expect(fallback.locate()?.path == "/usr/bin/ssh")
    }
}
