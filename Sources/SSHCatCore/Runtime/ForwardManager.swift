import Combine
import Foundation

/// Source of truth for the UI: one `ForwardRunner` per saved rule.
@MainActor
public final class ForwardManager: ObservableObject {
    @Published public private(set) var runners: [ForwardRunner] = []
    @Published public private(set) var loadError: String?
    @Published public private(set) var saveError: String?
    @Published public private(set) var canEditRules = false
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
        if reloadRules() {
            for runner in runners where runner.rule.autoStart { runner.start() }
        }
        events.start { [weak self] reason in self?.restartActive(reason: reason) }
    }

    /// Loads saved rules without changing any draft held by the UI.
    @discardableResult
    public func reloadRules() -> Bool {
        let loaded: [ForwardRule]
        do {
            loaded = try store.load()
        } catch {
            loadError = error.localizedDescription
            if let error = error as? ForwardStoreError, case .corrupt = error {
                canEditRules = true
            } else {
                canEditRules = false
            }
            return false
        }

        let loadedIDs = Set(loaded.map(\.id))
        for runner in runners where !loadedIDs.contains(runner.id) {
            runner.stop()
            runnerObservers[runner.id] = nil
            trackPID(id: runner.id, pid: nil)
        }
        runners.removeAll { !loadedIDs.contains($0.id) }

        for rule in loaded {
            if let runner = runner(id: rule.id) {
                runner.update(rule: rule)
            } else {
                attach(rule)
            }
        }
        let byID = Dictionary(runners.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        runners = loaded.compactMap { byID[$0.id] }
        loadError = nil
        canEditRules = true
        objectWillChange.send()
        return true
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

    @discardableResult
    public func add(_ rule: ForwardRule) -> Bool {
        guard ensureRulesLoaded() else { return false }
        guard persist(rules + [rule]) else { return false }
        attach(rule)
        return true
    }

    @discardableResult
    public func update(_ rule: ForwardRule) -> Bool {
        guard ensureRulesLoaded() else { return false }
        guard let runner = runner(id: rule.id) else { return false }
        let updated = rules.map { $0.id == rule.id ? rule : $0 }
        guard persist(updated) else { return false }
        runner.update(rule: rule)
        objectWillChange.send()
        return true
    }

    @discardableResult
    public func remove(id: UUID) -> Bool {
        guard ensureRulesLoaded() else { return false }
        guard let runner = runner(id: id), persist(rules.filter { $0.id != id }) else { return false }
        runner.stop()
        runnerObservers[id] = nil
        runners.removeAll { $0.id == id }
        trackPID(id: id, pid: nil)
        return true
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

    private func ensureRulesLoaded() -> Bool {
        if canEditRules { return true }
        guard loadError == nil else { return false }
        return reloadRules()
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

    @discardableResult
    private func persist(_ rules: [ForwardRule]) -> Bool {
        do {
            try store.save(rules)
            saveError = nil
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }
}
