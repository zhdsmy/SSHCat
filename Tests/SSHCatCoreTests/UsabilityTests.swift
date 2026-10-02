import Foundation
import Testing
@testable import SSHCatCore

private func exampleRule() -> ForwardRule {
    ForwardRule(name: "Web", user: "app", host: "devbox", port: 22, forwards: [PortForward()])
}

@Suite struct UsabilityTests {
    @Test func whitespaceAndEquivalentPortsDoNotLeavePhantomEdits() throws {
        let rule = exampleRule()
        var draft = RuleDraft(rule: rule, portText: " 022 ")
        draft.rule.name += " "
        draft.rule.host += "\n"
        draft.rule.user = " app "
        draft.rule.forwards[0].bindAddress += " "
        draft.ports[rule.forwards[0].id]?.bind = "08080"
        #expect(try draft.validated() == rule)
        #expect(!draft.isDirty(comparedTo: rule))
        var legacy = rule
        legacy.name += " "
        legacy.host = " devbox "
        #expect(!RuleDraft(rule: legacy).isDirty(comparedTo: legacy))
        #expect(!RuleDraft(rule: rule).isDirty(comparedTo: legacy))
    }

    @Test(arguments: ["", "abc", "0", "65536", "99999999999999999999999999"])
    func invalidForwardPortsStayInDraft(_ text: String) throws {
        let rule = exampleRule()
        var draft = RuleDraft(rule: rule)
        let id = rule.forwards[0].id
        draft.ports[id]?.bind = text
        #expect(draft.isDirty(comparedTo: rule))
        #expect(draft.issue(for: .bindPort(id)) != nil)
        #expect(throws: ForwardIssue.self) { try draft.validated() }
        let restored = draft
        #expect(restored.ports[id]?.bind == text)
        #expect(restored.rule.forwards[0].bindPort == 8080)
    }

    @Test func fieldErrorsIdentifyEveryAffectedInput() {
        var draft = RuleDraft(rule: exampleRule(), portText: "invalid")
        draft.rule.name = ""
        draft.rule.host = "-oProxyCommand=bad"
        draft.rule.identityFile = "relative-key"
        let id = draft.rule.forwards[0].id
        draft.ports[id]?.target = ""
        #expect(Set(draft.issues.map(\.field)) == [.name, .host, .sshPort, .identity, .targetPort(id)])
        draft.rule.forwards[0].kind = .dynamic
        #expect(draft.issue(for: .targetPort(id)) == nil)
    }

    @Test func firstConnectionCommandIsInteractiveAndNeverCarriesForwards() throws {
        var rule = exampleRule()
        rule.identityFile = "/Users/me/My Keys/id_ed25519"
        let command = try rule.firstConnectionCommand(executable: "/usr/bin/ssh")
        #expect(command.contains("BatchMode=no"))
        #expect(command.contains("StrictHostKeyChecking=ask"))
        #expect(command.contains("ClearAllForwardings=yes"))
        #expect(command.contains("-p 22"))
        #expect(command.contains("'/Users/me/My Keys/id_ed25519'"))
        #expect(command.hasSuffix("app@devbox"))
        #expect(!command.contains(" -N") && !command.contains(" -L"))
        #expect(try rule.arguments().contains("BatchMode=yes"))
        rule.host = "-oProxyCommand=bad"
        #expect(throws: ForwardIssue.self) { try rule.firstConnectionCommand(executable: "/usr/bin/ssh") }
    }

    @Test func archiveRoundTripPreservesParentPermissionsAndDisablesStartup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        var rule = exampleRule()
        rule.autoStart = true
        let url = directory.appendingPathComponent("rules.json")
        try RuleArchive.export([rule], to: url)
        let read = try RuleArchive.read(url)
        #expect(read == [rule])
        #expect((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue == 0o755)
        #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let prepared = RuleArchive.prepare(read, existing: [], duplicates: .skip)
        #expect(prepared.count == 1 && prepared[0].id != rule.id)
        #expect(prepared[0].forwards[0].id != rule.forwards[0].id)
        #expect(!prepared[0].autoStart)
        #expect(prepared[0].name == rule.name)
        #expect(RuleArchive.prepare(read, existing: prepared, duplicates: .skip).isEmpty)
        let copies = RuleArchive.prepare(read + read, existing: read, duplicates: .copy)
        #expect(copies.count == 2 && Set(copies.map(\.id)).count == 2)
        #expect(copies.allSatisfy { !$0.autoStart && $0.name != rule.name })
    }

    @Test func invalidImportIsRejectedWithoutChangingSourceFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("future.json")
        let future = Data(#"{"version":999,"rules":[]}"#.utf8)
        try future.write(to: url)
        #expect(throws: ForwardStoreError.self) { try RuleArchive.read(url) }
        #expect(try Data(contentsOf: url) == future)
        var rule = exampleRule()
        rule.host = "-oProxyCommand=bad"
        try ForwardStore.encode([rule]).write(to: url)
        #expect(throws: RuleArchive.ImportError.self) { try RuleArchive.read(url) }
        try ForwardStore.encode(Array(repeating: exampleRule(), count: 1001)).write(to: url)
        #expect(throws: RuleArchive.ImportError.self) { try RuleArchive.read(url) }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 8 * 1024 * 1024 + 1)
        try handle.close()
        #expect(throws: RuleArchive.ImportError.self) { try RuleArchive.read(url) }
        #expect(throws: CocoaError.self) { try RuleArchive.read(directory) }
    }

    @Test @MainActor func saveConnectRetryAndImportPreservePersistenceOrder() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ForwardStore(directory: directory)
        let manager = ForwardManager(store: store, makeConfig: {
            RunnerConfig(terminateGrace: 0.05, launch: { _ in
                LaunchSpec(executable: URL(fileURLWithPath: "/bin/sh"),
                           arguments: ["-c", "echo 'Authenticated to devbox using publickey.' >&2; exec sleep 30"])
            })
        })
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            manager.shutdown()
        }
        let rule = exampleRule()
        #expect(manager.add(rule))
        #expect(manager.saveAndStart(rule))
        let runner = try #require(manager.runner(id: rule.id))
        #expect(await waitUntil { runner.state == .running })
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        var edited = rule
        edited.host = "otherbox"
        #expect(!manager.saveAndStart(edited))
        #expect(runner.rule.host == "devbox" && runner.state == .running)
        #expect(!manager.importRules([edited], duplicates: .copy))
        #expect(manager.rules.count == 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        manager.retry(id: rule.id)
        #expect(await waitUntil { runner.state == .running })
        #expect(manager.importRules([edited], duplicates: .copy))
        #expect(manager.runners.count == 2)
        #expect(manager.runners[1].state == .stopped && !manager.runners[1].rule.autoStart)
        #expect(try store.load() == manager.rules)
        let conflict = try #require(manager.listenerConflicts(in: manager.rules[1]).first)
        #expect(conflict.ruleNames == [rule.name])
    }

    @Test @MainActor func retrySkipsBackoffAndRestartsFailedRules() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = ForwardManager(store: ForwardStore(directory: directory), makeConfig: {
            RunnerConfig(backoff: BackoffPolicy(base: 60, cap: 60), launch: { _ in
                LaunchSpec(executable: URL(fileURLWithPath: "/bin/sh"),
                           arguments: ["-c", "echo 'Connection refused' >&2; exit 255"])
            })
        })
        defer { manager.shutdown() }
        let rule = exampleRule()
        #expect(manager.add(rule))
        manager.setActive(true, id: rule.id)
        let runner = try #require(manager.runner(id: rule.id))
        #expect(await waitUntil { if case .reconnecting = runner.state { return true }; return false })
        manager.retry(id: rule.id)
        #expect(runner.state == .starting)
        #expect(await waitUntil { if case .reconnecting = runner.state { return true }; return false })
        var manual = rule
        manual.autoRestart = false
        #expect(manager.update(manual))
        manager.retry(id: rule.id)
        #expect(await waitUntil { if case .failed = runner.state { return true }; return false })
        manager.retry(id: rule.id)
        #expect(runner.state == .starting)
        #expect(await waitUntil { if case .failed = runner.state { return true }; return false })
    }
}
