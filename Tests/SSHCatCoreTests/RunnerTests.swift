import Foundation
import Testing
@testable import SSHCatCore

@MainActor
func waitUntil(timeout: TimeInterval = 5, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

private let fastBackoff = BackoffPolicy(base: 0.05, cap: 0.2, stableAfter: 60)

/// What `ssh -o LogLevel=VERBOSE -N` prints once the session is up, then stays quiet.
private let upScript = #"echo 'Authenticated to devbox ([10.0.0.1]:22) using "publickey".' >&2; exec sleep 30"#

private func shConfig(_ script: String, assumeRunningAfter: TimeInterval = 30) -> RunnerConfig {
    RunnerConfig(backoff: fastBackoff, terminateGrace: 0.5, assumeRunningAfter: assumeRunningAfter, launch: { _ in
        LaunchSpec(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script])
    })
}

private func rule(autoRestart: Bool = true) -> ForwardRule {
    ForwardRule(name: "t", user: "app", host: "devbox",
                forwards: [PortForward()], autoRestart: autoRestart)
}

private func isFailed(_ state: RunState) -> Bool {
    if case .failed = state { return true }
    return false
}

/// Drives ForwardRunner with /bin/sh scripts standing in for ssh.
@MainActor
@Suite struct RunnerTests {
    @Test func targetFailuresDoNotRestartTheSSHSession() async throws {
        var saved = rule()
        let remote = PortForward(kind: .remote, targetHost: "localhost", targetPort: 3000)
        saved.forwards.append(remote)
        let script = """
        echo 'Authenticated to devbox using publickey.' >&2
        echo 'channel 2: open failed: connect failed: Connection refused' >&2
        echo 'connect_to localhost port 3000: failed.' >&2
        exec sleep 30
        """
        let runner = ForwardRunner(rule: saved, config: shConfig(script))
        defer { runner.stop() }
        runner.start()
        #expect(await waitUntil { runner.targetFailures[remote.id] != nil && runner.unattributedTargetFailure != nil })
        #expect(runner.state == .running)
        #expect(runner.failure == nil)
        runner.clearTargetFailures()
        #expect(runner.targetFailures.isEmpty && runner.unattributedTargetFailure == nil)
    }

    @Test func hostKeyChangedContextSurvivesGenericFinalError() async {
        let script = """
        echo 'WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!' >&2
        echo 'Offending ED25519 key in /Users/me/.ssh/known_hosts:4' >&2
        echo '  ssh-keygen -f "/Users/me/.ssh/known_hosts" -R "gateway.example"' >&2
        echo 'Host key verification failed.' >&2
        exit 255
        """
        let runner = ForwardRunner(rule: rule(), config: shConfig(script))
        var notes: [String] = []
        runner.onNotify = { _, body in notes.append(body) }
        runner.start()
        #expect(await waitUntil { isFailed(runner.state) })
        #expect(runner.failure == .hostKeyChanged)
        #expect(runner.offendingKnownHostsFile == "/Users/me/.ssh/known_hosts")
        #expect(runner.hostKeyRemovalCommand == "ssh-keygen -f /Users/me/.ssh/known_hosts -R gateway.example")
        #expect(notes.first?.contains(L10n.core("failure.host_key_changed_hint")) == true)
    }

    @Test func becomesRunningWhileProcessLives() async {
        let runner = ForwardRunner(rule: rule(), config: shConfig(upScript))
        runner.start()
        #expect(await waitUntil { runner.state == .running })
        runner.stop()
        #expect(await waitUntil { runner.state == .stopped })
    }

    @Test func staysStartingUntilAuthenticated() async {
        // Still connecting or authenticating: alive is not the same as forwarding.
        let runner = ForwardRunner(rule: rule(), config: shConfig("exec sleep 30"))
        runner.start()
        try? await Task.sleep(nanoseconds: 500_000_000)
        #expect(runner.state == .starting)
        runner.stop()
    }

    @Test func assumesRunningWhenSSHNeverSaysAuthenticated() async {
        let runner = ForwardRunner(rule: rule(), config: shConfig("exec sleep 30", assumeRunningAfter: 0.2))
        runner.start()
        #expect(await waitUntil { runner.state == .running })
        runner.stop()
    }

    @Test func failureReasonSkipsVerboseChatter() async {
        let script = """
        echo 'Timeout, server devbox not responding.' >&2
        echo 'Transferred: sent 2112, received 2016 bytes, in 45.0 seconds' >&2
        echo 'Bytes per second: sent 46.9, received 44.8' >&2
        exit 255
        """
        let runner = ForwardRunner(rule: rule(autoRestart: false), config: shConfig(script))
        runner.start()
        #expect(await waitUntil { isFailed(runner.state) })
        #expect(runner.state == .failed(reason: "Timeout, server devbox not responding."))
    }

    @Test func failureNotificationCarriesHint() async {
        let runner = ForwardRunner(rule: rule(), config: shConfig("echo 'Host key verification failed.' >&2; exit 255"))
        var notes: [String] = []
        runner.onNotify = { _, body in notes.append(body) }
        runner.start()
        #expect(await waitUntil { isFailed(runner.state) })
        #expect(notes.first?.contains(L10n.core("failure.host_key_hint")) == true)
    }

    @Test func drainsOutputLargerThanPipeBuffer() async {
        // 256 KiB on each stream would deadlock if the pipes were read only after exit.
        let script = "head -c 262144 /dev/zero | tr '\\0' a; head -c 262144 /dev/zero | tr '\\0' b >&2; exit 3"
        let runner = ForwardRunner(rule: rule(autoRestart: false), config: shConfig(script))
        runner.start()
        #expect(await waitUntil(timeout: 20) { isFailed(runner.state) })
    }

    @Test func lineReaderSplitsAndKeepsUnterminatedTail() async throws {
        let pipe = Pipe()
        let lines = PipeReader.lines(pipe.fileHandleForReading)
        try pipe.fileHandleForWriting.write(contentsOf: Data("one\r\ntwo\n\nthree".utf8))
        try pipe.fileHandleForWriting.close()
        var got: [String] = []
        for await line in lines { got.append(line) }
        #expect(got == ["one", "two", "", "three"])
    }

    @Test func restartsWhenProcessExits() async {
        let runner = ForwardRunner(
            rule: rule(),
            config: shConfig("echo 'connect to host devbox port 22: Connection refused' >&2; exit 255")
        )
        runner.start()
        let sawReconnect = await waitUntil {
            if case .reconnecting(let attempt, _, _) = runner.state { return attempt >= 2 }
            return false
        }
        #expect(sawReconnect)
        runner.stop()
    }

    @Test func addressInUseFailsInsteadOfLooping() async {
        let runner = ForwardRunner(
            rule: rule(),
            config: shConfig("echo 'bind [127.0.0.1]:8080: Address already in use' >&2; exit 1")
        )
        var notes: [String] = []
        runner.onNotify = { _, body in notes.append(body) }
        runner.start()
        #expect(await waitUntil { isFailed(runner.state) })
        #expect(notes.first == L10n.core("notification.failed",
                                      "bind [127.0.0.1]:8080: Address already in use",
                                      "\n" + L10n.core("failure.port_hint")))
        if case .reconnecting = runner.state {
            Issue.record("bind failure should not reconnect")
        }
    }

    @Test func noAutoRestartStopsAfterExit() async {
        let runner = ForwardRunner(rule: rule(autoRestart: false), config: shConfig("exit 2"))
        runner.start()
        #expect(await waitUntil { isFailed(runner.state) })
    }

    @Test func missingBinaryFails() async {
        var cfg = shConfig("exit 0")
        cfg.launch = { _ in throw LaunchError.binaryNotFound }
        let runner = ForwardRunner(rule: rule(), config: cfg)
        runner.start()
        #expect(await waitUntil { isFailed(runner.state) })
        #expect(runner.state == .failed(reason: LaunchError.binaryNotFound.localizedDescription))
    }

    @Test func pidCallbackFiresOnStartAndExit() async {
        let runner = ForwardRunner(rule: rule(), config: shConfig(upScript))
        var events: [Int32?] = []
        runner.onPIDChange = { _, pid in events.append(pid) }
        runner.start()
        #expect(await waitUntil { runner.state == .running })
        runner.stop()
        // `last` is `Int32??`: nil means the array is empty, `.some(nil)` means the process exited.
        let sawExit = await waitUntil {
            guard events.count >= 2, let last = events.last else { return false }
            return last == nil
        }
        #expect(sawExit)
        #expect(events.first != nil)
    }

    @Test func editingRestartsActiveRunner() async {
        let runner = ForwardRunner(rule: rule(), config: shConfig(upScript))
        runner.start()
        #expect(await waitUntil { runner.state == .running })
        var edited = runner.rule
        edited.host = "otherbox"
        runner.update(rule: edited)
        #expect(runner.log.contains { $0.contains(L10n.core("runtime.configuration_changed")) })
        #expect(await waitUntil { runner.state == .running })
        runner.stop()
    }

    @Test func managerFindsClashingListeners() {
        let manager = ForwardManager(store: ForwardStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("SSHCatClash-\(UUID().uuidString)", isDirectory: true)),
                                     makeConfig: { shConfig(upScript) })
        var web = rule()
        web.forwards = [PortForward(bindAddress: "127.0.0.1", bindPort: 8080)]
        manager.add(web)

        var other = rule()
        other.id = UUID()
        other.forwards = [
            PortForward(bindAddress: "localhost", bindPort: 8080),
            PortForward(kind: .dynamic, bindAddress: "0.0.0.0", bindPort: 1080),
            PortForward(kind: .dynamic, bindAddress: "127.0.0.1", bindPort: 1080),
            PortForward(kind: .remote, bindAddress: "127.0.0.1", bindPort: 9000),
        ]
        #expect(manager.clashingEndpoints(in: other) == ["localhost:8080", "0.0.0.0:1080", "127.0.0.1:1080"])
        // A rule never clashes with its own saved copy.
        #expect(manager.clashingEndpoints(in: web).isEmpty)
    }

    @Test func managerPersistsRules() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SSHCatRun-\(UUID().uuidString)", isDirectory: true)
        let store = ForwardStore(directory: dir)
        let manager = ForwardManager(store: store, locator: BinaryLocator(customPath: { nil }, isExecutable: { _ in false }),
                                     makeConfig: { shConfig(upScript) })
        let saved = rule()
        manager.add(saved)
        let again = ForwardManager(store: store, makeConfig: { shConfig(upScript) })
        again.bootstrap()
        defer { again.shutdown() }
        #expect(again.rules == [saved])
        try? FileManager.default.removeItem(at: dir)
    }
}
