import Foundation
import Testing
@testable import SSHCatCore

private func persistenceRule() -> ForwardRule {
    var rule = ForwardRule(
        name: "web",
        user: "app",
        host: "devbox",
        forwards: [PortForward(bindPort: 8080)]
    )
    rule.autoStart = false
    return rule
}

@MainActor
private func waitUntil(_ predicate: () -> Bool) async -> Bool {
    for _ in 0..<100 {
        if predicate() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return predicate()
}

@Suite struct PersistenceSafetyTests {
    @Test func unreadableStoreBlocksSaveUntilSuccessfulReload() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("SSHCatStore-\(UUID().uuidString)", isDirectory: true)
        let store = ForwardStore(directory: dir)
        defer { try? fm.removeItem(at: dir) }

        let original = [persistenceRule()]
        try store.save(original)
        let data = try Data(contentsOf: store.fileURL)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: store.fileURL.path)
        #expect(throws: (any Error).self) { try store.load() }

        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.fileURL.path)
        #expect(throws: ForwardStoreError.self) { try store.save([]) }
        #expect(try Data(contentsOf: store.fileURL) == data)
        #expect(try store.load() == original)
        try store.save([])
        #expect(try store.load().isEmpty)
    }

    @Test func unsupportedVersionIsPreservedAndBlocksSave() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("SSHCatVersion-\(UUID().uuidString)", isDirectory: true)
        let store = ForwardStore(directory: dir)
        defer { try? fm.removeItem(at: dir) }

        let future = Data(#"{"version":999,"futureRules":{"important":"keep"}}"#.utf8)
        try SecureFile.write(future, to: store.fileURL)
        do {
            _ = try store.load()
            Issue.record("An unsupported version should not load")
        } catch ForwardStoreError.unsupportedVersion(999) {
        } catch {
            Issue.record("Unexpected load error: \(error)")
        }
        #expect(throws: ForwardStoreError.self) { try store.save([]) }
        #expect(try Data(contentsOf: store.fileURL) == future)
        #expect(try fm.contentsOfDirectory(atPath: dir.path) == ["forwards.json"])

        try Data(#"{"version":1,"rules":[]}"#.utf8).write(to: store.fileURL)
        #expect(try store.load().isEmpty)
        try store.save([])
        let envelope = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
        #expect(envelope["version"] as? Int == 1)
    }

    @Test func failedQuarantineKeepsCorruptFileAndBlocksSave() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("SSHCatQuarantine-\(UUID().uuidString)", isDirectory: true)
        let store = ForwardStore(directory: dir)
        let corrupt = Data("broken JSON".utf8)
        defer {
            try? fm.setAttributes([.immutable: false], ofItemAtPath: store.fileURL.path)
            try? fm.removeItem(at: dir)
        }

        try SecureFile.write(corrupt, to: store.fileURL)
        try fm.setAttributes([.immutable: true], ofItemAtPath: store.fileURL.path)
        do {
            _ = try store.load()
            Issue.record("An unmovable corrupt file should fail to load")
        } catch ForwardStoreError.corrupt {
            Issue.record("A failed quarantine must not claim that a backup exists")
        } catch { }
        try fm.setAttributes([.immutable: false], ofItemAtPath: store.fileURL.path)
        #expect(throws: ForwardStoreError.self) { try store.save([]) }
        #expect(try Data(contentsOf: store.fileURL) == corrupt)
        #expect(try fm.contentsOfDirectory(atPath: dir.path) == ["forwards.json"])

        #expect(throws: ForwardStoreError.self) { try store.load() }
        try store.save([])
        let backups = try fm.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("forwards.corrupt-") }
        #expect(backups.count == 1)
    }

    @MainActor
    @Test func addLoadsBeforeBootstrapForSnapshotStaging() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SSHCatSnapshot-\(UUID().uuidString)", isDirectory: true)
        let manager = ForwardManager(
            store: ForwardStore(directory: dir),
            locator: BinaryLocator(customPath: { nil }, isExecutable: { _ in false })
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        var rule = persistenceRule()
        rule.host = ""
        #expect(manager.add(rule))
        #expect(manager.canEditRules)
        #expect(manager.rules == [rule])
    }

    @MainActor
    @Test func quarantinedCorruptStoreCanBeReplacedWithoutHidingLoadError() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("SSHCatCorrupt-\(UUID().uuidString)", isDirectory: true)
        let store = ForwardStore(directory: dir)
        let manager = ForwardManager(
            store: store,
            locator: BinaryLocator(customPath: { nil }, isExecutable: { _ in false })
        )
        defer {
            manager.shutdown()
            try? fm.removeItem(at: dir)
        }

        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("broken JSON".utf8).write(to: store.fileURL)
        manager.bootstrap()
        #expect(manager.loadError != nil)
        #expect(manager.canEditRules)

        let rule = persistenceRule()
        #expect(manager.add(rule))
        #expect(manager.loadError != nil)
        #expect(try store.load() == [rule])
        let backups = try fm.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("forwards.corrupt-") }
        #expect(backups.count == 1)
    }

    @MainActor
    @Test func reloadRecoversManagerAfterReadFailure() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("SSHCatReload-\(UUID().uuidString)", isDirectory: true)
        let store = ForwardStore(directory: dir)
        let rule = persistenceRule()
        try store.save([rule])
        let original = try Data(contentsOf: store.fileURL)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: store.fileURL.path)
        let manager = ForwardManager(
            store: store,
            locator: BinaryLocator(customPath: { nil }, isExecutable: { _ in false })
        )
        defer {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.fileURL.path)
            manager.shutdown()
            try? fm.removeItem(at: dir)
        }

        manager.bootstrap()
        #expect(manager.rules.isEmpty)
        #expect(manager.loadError != nil)
        #expect(!manager.canEditRules)
        var added = persistenceRule()
        added.id = UUID()
        #expect(!manager.add(added))
        #expect(manager.saveError == nil)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.fileURL.path)
        #expect(try Data(contentsOf: store.fileURL) == original)
        #expect(manager.reloadRules())
        #expect(manager.rules == [rule])
        #expect(manager.loadError == nil)
        #expect(manager.canEditRules)
        #expect(manager.saveError == nil)
    }

    @MainActor
    @Test func failedMutationsKeepExistingFakeSSHRunnerAlive() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("SSHCatMutation-\(UUID().uuidString)", isDirectory: true)
        let store = ForwardStore(directory: dir)
        let original = persistenceRule()
        try store.save([original])
        let manager = ForwardManager(
            store: store,
            locator: BinaryLocator(customPath: { nil }, isExecutable: { _ in false }),
            makeConfig: {
                RunnerConfig(assumeRunningAfter: 0.02, launch: { _ in
                    LaunchSpec(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exec /bin/sleep 30"])
                })
            }
        )
        defer {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            manager.shutdown()
            try? fm.removeItem(at: dir)
        }

        manager.bootstrap()
        let runner = try #require(manager.runner(id: original.id))
        manager.setActive(true, id: original.id)
        #expect(await waitUntil { runner.state == .running })

        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        var added = persistenceRule()
        added.id = UUID()
        var edited = original
        edited.host = "otherbox"
        #expect(!manager.add(added))
        #expect(!manager.update(edited))
        #expect(!manager.remove(id: original.id))
        #expect(manager.rules == [original])
        #expect(runner.rule == original)
        #expect(runner.state.isActive)
        #expect(manager.saveError != nil)
        #expect(manager.loadError == nil)
        #expect(try store.load() == [original])
        #expect(manager.reloadRules())
        #expect(runner.state.isActive)
        #expect(manager.saveError != nil)

        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        #expect(manager.remove(id: original.id))
        #expect(manager.rules.isEmpty)
        #expect(runner.state == .stopped)
        #expect(manager.saveError == nil)
    }
}
