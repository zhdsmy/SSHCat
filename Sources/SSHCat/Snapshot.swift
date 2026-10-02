#if DEBUG
import AppKit
import SwiftUI
import SSHCatCore

/// Runs before the app delegate exists. Every rule and process belongs to a temporary world;
/// rendering does not read SSH config, ask for notification permission, or register login items.
@MainActor
enum Snapshot {
    static func run(arguments: [String]) -> Never {
        guard let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count else {
            exit(64)
        }
        let output = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        let requested = arguments.first { $0.hasPrefix("--language=") }.map { String($0.dropFirst(11)) } ?? "en"
        guard let language = AppLanguage(rawValue: requested), language != .system else { exit(64) }
        Entry.configureLanguage(language)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: arguments.contains("--dark") ? .darkAqua : .aqua)
        Task {
            do {
                try await capture(to: output, language: language)
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
                exit(1)
            }
        }
        app.run()
        exit(0)
    }

    private static func capture(to output: URL, language: AppLanguage) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        let directory = fm.temporaryDirectory.appendingPathComponent("SSHCat-snapshot-\(UUID().uuidString)")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("ssh")
        try Data("#!/bin/sh\nprintf 'OpenSSH_example\\n'\n".utf8).write(to: binary)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let locator = BinaryLocator(customPath: { nil }, fallback: binary.path, environmentPATH: nil)
        let manager = ForwardManager(store: ForwardStore(directory: directory), locator: locator, makeConfig: {
            RunnerConfig(backoff: BackoffPolicy(base: 60, cap: 60), terminateGrace: 0.1, launch: { rule in
                let script: String
                if rule.host == "missing.example" {
                    script = "echo 'Host key verification failed.' >&2; exit 255"
                } else if rule.host == "offline.example" {
                    script = "echo 'Connection refused' >&2; exit 255"
                } else {
                    script = "echo 'Authenticated to devbox using publickey.' >&2; exec sleep 120"
                }
                return LaunchSpec(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script])
            })
        })
        defer { manager.shutdown() }
        let navigation = Navigation()
        let renderer = SnapshotRenderer(output: output, manager: manager, navigation: navigation)
        manager.reloadRules()
        manager.refreshBinary()
        try await renderer.page("empty-menu", MenuContent())
        try await renderer.page("empty-manage", ManageView(snapshotMode: true), size: CGSize(width: 900, height: 640))

        let rules = [
            ForwardRule(name: "Development Website", host: "devbox", forwards: [PortForward()], autoStart: true),
            ForwardRule(name: "SOCKS Proxy", host: "gateway", forwards: [PortForward(kind: .dynamic, bindPort: 1080)]),
            ForwardRule(name: "Remote Demo", host: "demo", forwards: [PortForward(kind: .remote, bindPort: 9000, targetPort: 3000)]),
            ForwardRule(name: "Host Key Check", host: "missing.example", forwards: [PortForward(bindPort: 8081)]),
            ForwardRule(name: "Waiting for Network", host: "offline.example", forwards: [PortForward(bindPort: 8082)]),
        ]
        for rule in rules { manager.add(rule) }
        for index in [0, 3, 4] { manager.setActive(true, id: rules[index].id) }
        for _ in 0..<100 {
            if manager.runners.allSatisfy({ $0.state != .starting }) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        assert(manager.runner(id: rules[0].id)?.state == .running)
        assert(manager.runner(id: rules[3].id)?.state == .failed(reason: "Host key verification failed."))
        navigation.selection = rules[0].id
        try await renderer.page("menu", MenuContent())
        try await renderer.page("manage", ManageView(snapshotMode: true), size: CGSize(width: 900, height: 700))
        navigation.selection = rules[3].id
        try await renderer.page("failed", ManageView(snapshotMode: true), size: CGSize(width: 760, height: 620))
        navigation.selection = rules[4].id
        try await renderer.page("reconnecting", ManageView(snapshotMode: true), size: CGSize(width: 760, height: 620))
        var draft = rules[0]
        draft.name = "Development Website · Draft"
        navigation.drafts[draft.id] = RuleDraft(rule: draft, portText: "invalid")
        navigation.show(draft.id)
        try await renderer.page("draft", ManageView(snapshotMode: true), size: CGSize(width: 900, height: 700))
        navigation.drafts[draft.id] = nil
        navigation.searchText = "1080"
        try await renderer.page("search", ManageView(snapshotMode: true), size: CGSize(width: 900, height: 700))
        navigation.searchText = "no-matching-rule"
        try await renderer.page("search-empty", ManageView(snapshotMode: true), size: CGSize(width: 900, height: 700))
        navigation.searchText = ""
        let suite = "SSHCat-snapshot-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.language = language
        try await renderer.page("settings", SettingsView(settings: settings, snapshotMode: true),
                                size: CGSize(width: 520, height: 680))
        try await renderer.page("update-available", SettingsView(settings: settings, snapshotMode: true, update: .available("v0.2.0")),
                                size: CGSize(width: 520, height: 680))
        var long = rules[2]
        long.name = "Demo Environment · " + String(repeating: "Long-running Port Forward ", count: 8)
        manager.update(long)
        navigation.selection = long.id
        try await renderer.page("narrow-long", ManageView(snapshotMode: true), size: CGSize(width: 760, height: 580))
        for index in 1...18 {
            manager.add(ForwardRule(name: "Project \(index)", host: "devbox", forwards: [PortForward(bindPort: 10000 + index)]))
        }
        try await renderer.page("many-menu", MenuContent())

        let unreadableStore = ForwardStore(directory: directory.appendingPathComponent("future-data"))
        try SecureFile.write(Data(#"{"version":999,"rules":[]}"#.utf8), to: unreadableStore.fileURL)
        let unreadable = ForwardManager(store: unreadableStore, locator: locator, makeConfig: {
            RunnerConfig(launch: { _ in throw LaunchError.binaryNotFound })
        })
        unreadable.reloadRules()
        try await SnapshotRenderer(output: output, manager: unreadable, navigation: Navigation())
            .page("storage-error", ManageView(snapshotMode: true), size: CGSize(width: 900, height: 700))
    }
}

@MainActor
private final class SnapshotRenderer {
    let output: URL
    let manager: ForwardManager
    let navigation: Navigation
    private var windows: [NSWindow] = []

    init(output: URL, manager: ForwardManager, navigation: Navigation) {
        self.output = output
        self.manager = manager
        self.navigation = navigation
    }

    func page<V: View>(_ name: String, _ view: V, size: CGSize? = nil) async throws {
        let root = view.environmentObject(manager).environmentObject(navigation)
            .environment(\.locale, L10n.locale)
            .frame(width: size?.width, height: size?.height, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size ?? host.fittingSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        windows.append(window)
        try await Task.sleep(nanoseconds: 250_000_000)
        host.layoutSubtreeIfNeeded()
        try save(name, host)
        if let scroll = scrollViews(in: host).filter({
            $0.contentSize.width > host.bounds.width / 2 && $0.contentSize.height > 100
                && ($0.documentView?.bounds.height ?? 0) > $0.contentSize.height + 1
        }).max(by: { $0.contentSize.width < $1.contentSize.width }), let document = scroll.documentView {
            let end = document.bounds.height - scroll.contentSize.height
            var offset: CGFloat = 0
            for index in 1...10 {
                guard offset < end else { break }
                offset = min(end, offset + scroll.contentSize.height * 0.85)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? offset : end - offset))
                scroll.reflectScrolledClipView(scroll.contentView)
                try await Task.sleep(nanoseconds: 100_000_000)
                host.layoutSubtreeIfNeeded()
                try save("\(name)-scroll-\(index)", host)
            }
        }
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
    }

    private func save<V: View>(_ name: String, _ host: NSHostingView<V>) throws {
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: output.appendingPathComponent("\(name).png"))
        print("\(name).png")
    }
}
#endif
