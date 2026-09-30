import Combine
import Foundation

/// Source of truth for the UI: one `ForwardRunner` per saved rule.
@MainActor
public final class ForwardManager: ObservableObject {
    @Published public private(set) var runners: [ForwardRunner] = []
    @Published public private(set) var loadError: String?
    @Published public private(set) var binaryPath: String?
    /// First line of `ssh -V` for the located binary, for Settings and diagnostics.
    @Published public private(set) var sshVersion: String?

    /// (title, body) for failure alerts.
    public var onNotify: ((String, String) -> Void)?

    private let store: ForwardStore
    private let pids: PIDTracker
    private let locator: BinaryLocator
    private let makeConfig: () -> RunnerConfig
    private var runnerObservers: [UUID: AnyCancellable] = [:]
    private var livePIDs: [String: Int32] = [:]
    private let events = SystemEvents()

    public init(
        store: ForwardStore = ForwardStore(directory: ForwardStore.defaultDirectory()),
        locator: BinaryLocator = BinaryLocator(),
        makeConfig: (() -> RunnerConfig)? = nil
    ) {
        self.store = store
        self.locator = locator
        self.pids = PIDTracker(directory: store.directory)
        self.makeConfig = makeConfig ?? { RunnerConfig.live(locator: locator) }
    }

    public var rules: [ForwardRule] { runners.map(\.rule) }

    public func runner(id: UUID?) -> ForwardRunner? {
        guard let id else { return nil }
        return runners.first { $0.id == id }
    }

    /// Reaps orphans from a previous run, loads rules, starts `autoStart` rules, and listens for
    /// wake / network changes.
    public func bootstrap() {
        pids.reapOrphans()
        refreshBinary()
        let loaded: [ForwardRule]
        do {
            loaded = try store.load()
            loadError = nil
        } catch {
            loaded = []
            loadError = error.localizedDescription
        }
        for rule in loaded { attach(rule) }
        for runner in runners where runner.rule.autoStart { runner.start() }
        events.start { [weak self] reason in self?.restartActive(reason: reason) }
    }

    public func shutdown() {
        events.stop()
        for runner in runners { runner.terminateSynchronously() }
        pids.save([:])
    }

    public func refreshBinary() {
        let path = locator.locate()?.path
        guard path != binaryPath || sshVersion == nil else { return }
        binaryPath = path
        sshVersion = nil
        guard let path else { return }
        Task { [weak self] in
            let version = await Task.detached { Self.probeVersion(path) }.value
            guard let self, self.binaryPath == path else { return }
            self.sshVersion = version
        }
    }

    /// Local listeners in `rule` that another saved rule, or another forward in the same rule, also binds.
    public func clashingEndpoints(in rule: ForwardRule) -> [String] {
        let others = runners.filter { $0.id != rule.id }.flatMap(\.rule.forwards)
        var clashes: [String] = []
        for (index, forward) in rule.forwards.enumerated() {
            let siblings = rule.forwards.enumerated().filter { $0.offset != index }.map(\.element)
            guard (others + siblings).contains(where: forward.clashes(with:)),
                  let endpoint = forward.localEndpoint, !clashes.contains(endpoint) else { continue }
            clashes.append(endpoint)
        }
        return clashes
    }

    /// `ssh -V` prints to stderr, e.g. `OpenSSH_10.3p1, LibreSSL 3.3.6`.
    private nonisolated static func probeVersion(_ path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-V"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let line = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).first
        return line.map(String.init)
    }

    public func add(_ rule: ForwardRule) {
        attach(rule)
        persist()
    }

    public func update(_ rule: ForwardRule) {
        runner(id: rule.id)?.update(rule: rule)
        persist()
        objectWillChange.send()
    }

    public func remove(id: UUID) {
        guard let runner = runner(id: id) else { return }
        runner.stop()
        runnerObservers[id] = nil
        runners.removeAll { $0.id == id }
        trackPID(id: id, pid: nil)
        persist()
    }

    public func setActive(_ active: Bool, id: UUID) {
        guard let runner = runner(id: id) else { return }
        if active { runner.start() } else { runner.stop() }
    }

    /// Wake / network change: restart every session the supervisor is keeping alive.
    public func restartActive(reason: String) {
        for runner in runners where runner.state.isActive {
            runner.restart(reason: reason)
        }
    }

    private func attach(_ rule: ForwardRule) {
        let runner = ForwardRunner(rule: rule, config: makeConfig())
        runner.onPIDChange = { [weak self] id, pid in self?.trackPID(id: id, pid: pid) }
        runner.onNotify = { [weak self] title, body in self?.onNotify?(title, body) }
        runnerObservers[rule.id] = runner.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        runners.append(runner)
    }

    private func trackPID(id: UUID, pid: Int32?) {
        if let pid {
            livePIDs[id.uuidString] = pid
        } else {
            livePIDs.removeValue(forKey: id.uuidString)
        }
        pids.save(livePIDs)
    }

    private func persist() {
        do {
            try store.save(runners.map(\.rule))
        } catch {
            loadError = error.localizedDescription
        }
    }
}
