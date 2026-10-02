import Combine
import Foundation

public enum RunState: Equatable, Sendable {
    case stopped
    case starting
    case running
    case reconnecting(attempt: Int, retryAt: Date, reason: String)
    case failed(reason: String)

    /// The supervisor is (or will shortly be) keeping an ssh process alive.
    public var isActive: Bool {
        switch self {
        case .starting, .running, .reconnecting: return true
        case .stopped, .failed: return false
        }
    }
}

public enum LaunchError: Error, Equatable, Sendable, LocalizedError {
    case binaryNotFound

    public var errorDescription: String? {
        switch self {
        case .binaryNotFound: return L10n.core("runtime.binary_missing")
        }
    }
}

public struct LaunchSpec: Sendable {
    public var executable: URL
    public var arguments: [String]

    public init(executable: URL, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
}

public struct RunnerConfig: Sendable {
    public var backoff: BackoffPolicy
    public var terminateGrace: TimeInterval
    public var logCapacity: Int
    /// A process still alive this long without printing `Authenticated to …` counts as running,
    /// for ssh builds that log differently. Longer than ConnectTimeout, so a dead host fails first.
    public var assumeRunningAfter: TimeInterval
    public var launch: @Sendable (ForwardRule) throws -> LaunchSpec

    public init(
        backoff: BackoffPolicy = BackoffPolicy(),
        terminateGrace: TimeInterval = 3,
        logCapacity: Int = 200,
        assumeRunningAfter: TimeInterval = 20,
        launch: @escaping @Sendable (ForwardRule) throws -> LaunchSpec
    ) {
        self.backoff = backoff
        self.terminateGrace = terminateGrace
        self.logCapacity = logCapacity
        self.assumeRunningAfter = assumeRunningAfter
        self.launch = launch
    }

    public static func live(locator: BinaryLocator) -> RunnerConfig {
        RunnerConfig(launch: { rule in
            guard let exe = locator.locate() else { throw LaunchError.binaryNotFound }
            return LaunchSpec(executable: exe, arguments: try rule.arguments())
        })
    }
}

/// Supervises one rule: launches ssh, marks it running once ssh reports it has authenticated, and
/// restarts with backoff when it exits. After that ssh -N stays quiet, so "still alive" is the health signal.
@MainActor
public final class ForwardRunner: ObservableObject, Identifiable {
    public nonisolated let id: UUID
    public private(set) var rule: ForwardRule

    @Published public private(set) var state: RunState = .stopped
    @Published public private(set) var log: [String] = []

    /// Called with the child pid when a process starts and with nil when it has exited.
    public var onPIDChange: ((UUID, Int32?) -> Void)?
    /// (title, body) for alerts the user should see even with the window closed.
    public var onNotify: ((String, String) -> Void)?

    private let config: RunnerConfig
    private var task: Task<Void, Never>?
    private var generation = 0
    private var currentBox: ProcessBox?
    private var runTail: [String] = []

    public init(rule: ForwardRule, config: RunnerConfig) {
        self.id = rule.id
        self.rule = rule
        self.config = config
    }

    public func start() {
        guard !state.isActive else { return }
        generation += 1
        let gen = generation
        let previous = task
        state = .starting
        task = Task { [weak self] in
            // A previous run may still be shutting down; wait so its listen ports are free.
            await previous?.value
            await self?.supervise(gen: gen)
        }
    }

    public func stop() {
        generation += 1
        // Cancel is cooperative and may not reach `withTaskCancellationHandler` before the
        // caller returns. Signal the child immediately so the listen port is released.
        currentBox?.terminate(grace: config.terminateGrace)
        task?.cancel()
        state = .stopped
    }

    public func restart(reason: String) {
        guard state.isActive else { return }
        appendLog(L10n.core("runtime.restarting", reason))
        stop()
        start()
    }

    /// Applies edited settings. A running session is restarted only when the ssh command would change.
    public func update(rule newRule: ForwardRule) {
        let relaunch = newRule.user != rule.user || newRule.host != rule.host || newRule.port != rule.port
            || newRule.identityFile != rule.identityFile || newRule.forwards != rule.forwards
        rule = newRule
        if relaunch, state.isActive { restart(reason: L10n.core("runtime.configuration_changed")) }
    }

    /// Blocking stop for app quit, when no scheduled work will get a chance to run.
    public func terminateSynchronously(timeout: TimeInterval = 1.5) {
        generation += 1
        task?.cancel()
        state = .stopped
        currentBox?.terminateAndWait(timeout: timeout)
    }

    private func isCurrent(_ gen: Int) -> Bool { gen == generation }

    private func setState(_ gen: Int, _ new: RunState) {
        guard isCurrent(gen) else { return }
        state = new
    }

    private func supervise(gen: Int) async {
        var attempt = 0
        while isCurrent(gen) {
            let spec: LaunchSpec
            do { spec = try config.launch(rule) } catch {
                setState(gen, .failed(reason: error.localizedDescription))
                return
            }
            setState(gen, .starting)
            let outcome = await runOnce(gen: gen, spec: spec)
            guard isCurrent(gen) else { return }

            let reason = describe(outcome)
            appendLog(L10n.core("runtime.process_exited", reason))

            if outcome.launchFailed || SSHFailure.isPermanent(outcome.tail) || !rule.autoRestart {
                setState(gen, .failed(reason: reason))
                let hint = SSHFailure.hint(for: reason).map { "\n\($0)" } ?? ""
                onNotify?(rule.name, L10n.core("notification.failed", reason, hint))
                return
            }

            if outcome.ranFor >= config.backoff.stableAfter { attempt = 0 }
            attempt += 1
            let delay = config.backoff.delay(forAttempt: attempt)
            setState(gen, .reconnecting(attempt: attempt,
                                        retryAt: Date().addingTimeInterval(delay),
                                        reason: reason))
            if attempt == 3 || attempt == 8 {
                onNotify?(rule.name, L10n.core("notification.reconnecting", attempt, reason))
            }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    private struct Outcome {
        var status: Int32?
        var ranFor: TimeInterval
        var launchFailed: Bool
        var launchError: String?
        var tail: [String]
    }

    private func describe(_ outcome: Outcome) -> String {
        if let error = outcome.launchError { return L10n.core("runtime.launch_failed", error) }
        if let last = outcome.tail.last(where: { !$0.isEmpty && !SSHLog.isInformational($0) }) { return last }
        return L10n.core("runtime.exit_status", outcome.status.map(String.init) ?? "?")
    }

    private func runOnce(gen: Int, spec: LaunchSpec) async -> Outcome {
        let process = Process()
        process.executableURL = spec.executable
        process.arguments = spec.arguments
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let (exits, exitContinuation) = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { p in
            exitContinuation.yield(p.terminationStatus)
            exitContinuation.finish()
        }
        let box = ProcessBox(process)
        runTail = []
        let started = Date()

        if Task.isCancelled {
            return Outcome(status: nil, ranFor: 0, launchFailed: false, launchError: nil, tail: [])
        }

        do {
            try process.run()
        } catch {
            return Outcome(status: nil, ranFor: 0, launchFailed: true,
                           launchError: error.localizedDescription, tail: [])
        }
        currentBox = box
        onPIDChange?(rule.id, process.processIdentifier)
        // Until `Authenticated to …` arrives ssh may still be resolving, connecting, or authenticating.
        let fallback = Task { [weak self, wait = config.assumeRunningAfter] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled, let self, self.currentBox === box, self.state == .starting else { return }
            self.setState(gen, .running)
        }

        let readers = [errPipe, outPipe].map { pipe in
            Task { [weak self] in
                for await line in PipeReader.lines(pipe.fileHandleForReading) {
                    self?.handleLine(line, gen: gen)
                }
            }
        }

        let status: Int32? = await withTaskCancellationHandler {
            if Task.isCancelled { box.terminate(grace: config.terminateGrace) }
            for await s in exits { return s }
            return nil
        } onCancel: { [grace = config.terminateGrace] in
            box.terminate(grace: grace)
        }

        fallback.cancel()
        for reader in readers { await reader.value }
        if currentBox === box { currentBox = nil }
        onPIDChange?(rule.id, nil)

        return Outcome(status: status, ranFor: Date().timeIntervalSince(started),
                       launchFailed: false, launchError: nil, tail: runTail)
    }

    private func handleLine(_ line: String, gen: Int) {
        guard isCurrent(gen) else { return }
        if SSHLog.isAuthenticated(line), state == .starting { state = .running }
        appendLog(line)
        runTail.append(line)
        if runTail.count > 20 { runTail.removeFirst(runTail.count - 20) }
    }

    private func appendLog(_ line: String) {
        log.append(line)
        if log.count > config.logCapacity { log.removeFirst(log.count - config.logCapacity) }
    }
}
