#if DEBUG
import AppKit
import SwiftUI
import SSHCatCore

/// Runs before the app delegate exists. Every rule and process belongs to a temporary world;
/// rendering does not read SSH config, ask for notification permission, or register login items.
@MainActor
enum Snapshot {
    static let importPreviewRequested = Notification.Name("SSHCat.snapshot.importPreview")

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
                    script = "echo 'No ED25519 host key is known for devbox and you have requested strict checking.' >&2; echo 'Host key verification failed.' >&2; exit 255"
                } else if rule.host == "changed.example" {
                    script = """
                    echo 'WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!' >&2
                    echo 'Offending ED25519 key in /Users/me/.ssh/known_hosts:4' >&2
                    echo '  ssh-keygen -f "/Users/me/.ssh/known_hosts" -R "changed.example"' >&2
                    echo 'Host key verification failed.' >&2
                    exit 255
                    """
                } else if rule.host == "target-errors.example" {
                    script = "echo 'Authenticated to devbox using publickey.' >&2; echo 'channel 2: open failed: connect failed: Connection refused' >&2; echo 'connect_to localhost port 3000: failed.' >&2; exec sleep 120"
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
        try await renderer.checkImportPresentation(directory: directory)
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
        try await renderer.checkPortEditing(rule: rules[0], other: rules[1])
        renderer.checkQuitProtection(rule: rules[0])
        navigation.selection = rules[0].id
        try await renderer.page("menu", MenuContent())
        try await renderer.page("manage", ManageView(snapshotMode: true), size: CGSize(width: 900, height: 700))
        try await renderer.page("overview", Overview(), size: Overview.size, scale: 2)
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
        var invalidPorts = RuleDraft(rule: rules[0])
        invalidPorts.ports[rules[0].forwards[0].id]?.bind = ""
        invalidPorts.ports[rules[0].forwards[0].id]?.target = "70000"
        navigation.drafts[rules[0].id] = invalidPorts
        navigation.show(rules[0].id)
        try await renderer.page("port-validation", ManageView(snapshotMode: true), size: CGSize(width: 760, height: 700))
        navigation.drafts[rules[0].id] = nil
        navigation.filter = .failed
        try await renderer.page("filter-failed", MenuContent())
        navigation.filter = .all
        try await renderer.page("host-picker", HostPicker(hosts: ["devbox", "gateway", "lab-v6"], refresh: {}, select: { _ in }))
        try await renderer.page("import-preview", ImportPreview(rules: [rules[0],
            ForwardRule(name: "New Project", host: "newbox", forwards: [PortForward(bindPort: 9090)])]))
        try renderer.quitPrompt(names: [rules[0].name, rules[1].name])
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
        settings.identityAgent = "/Users/me/Agent Sockets/agent.sock"
        try await renderer.page("settings", SettingsView(settings: settings, snapshotMode: true),
                                size: CGSize(width: 520, height: 680))
        try await renderer.page("update-available", SettingsView(settings: settings, snapshotMode: true, update: .available("v0.2.0")),
                                size: CGSize(width: 520, height: 680))
        try await renderer.page("permissions", SettingsView(settings: settings, snapshotMode: true,
                                                           notificationStatus: .denied, loginStatus: .requiresApproval),
                                size: CGSize(width: 520, height: 680))
        let targetErrors = ForwardRule(name: "Target Errors", host: "target-errors.example", forwards: [PortForward(bindPort: 8180),
            PortForward(kind: .remote, bindPort: 9100, targetHost: "localhost", targetPort: 3000)])
        let changed = ForwardRule(name: "Changed Host Key", host: "changed.example", forwards: [PortForward(bindPort: 8181)])
        let reverse = ForwardRule(name: "Remote SOCKS", host: "devbox", forwards: [PortForward(kind: .remoteDynamic, bindPort: 1080)])
        for rule in [targetErrors, changed, reverse] { manager.add(rule) }
        manager.setActive(true, id: targetErrors.id)
        manager.setActive(true, id: changed.id)
        for _ in 0..<100 {
            if manager.runner(id: targetErrors.id)?.unattributedTargetFailure != nil,
               manager.runner(id: targetErrors.id)?.targetFailures.count == 1,
               manager.runner(id: changed.id)?.state == .failed(reason: "Host key verification failed.") { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        assert(manager.runner(id: targetErrors.id)?.state == .running)
        assert(manager.runner(id: targetErrors.id)?.targetFailures.count == 1)
        assert(manager.runner(id: changed.id)?.failure == .hostKeyChanged)
        navigation.show(targetErrors.id)
        try await renderer.page("target-failures", ManageView(snapshotMode: true), size: CGSize(width: 760, height: 700))
        navigation.show(changed.id)
        try await renderer.page("host-key-changed", ManageView(snapshotMode: true), size: CGSize(width: 760, height: 700))
        navigation.show(reverse.id)
        try await renderer.page("remote-socks", ManageView(snapshotMode: true), size: CGSize(width: 760, height: 700))
        let config = SSHConfiguration(output: """
        user app
        hostname devbox.example
        port 2222
        proxyjump gateway
        identityfile /Users/me/My Keys/id_ed25519
        identityfile ~/.ssh/id_ed25519
        identityagent /Users/me/Agent Sockets/agent.sock
        hostkeyalias trusted-devbox
        userknownhostsfile /Users/me/.ssh/known_hosts
        localforward 8181 127.0.0.1:8080
        localforward 9090 127.0.0.1:9090
        """)
        let request = SSHConfigurationRequest(rule: changed, executable: binary, identityAgent: settings.identityAgent,
                                               knownHostsFile: "/Users/me/.ssh/known_hosts",
                                               hostKeyRemovalCommand: "ssh-keygen -f /Users/me/.ssh/known_hosts -R changed.example",
                                               sshVersion: "OpenSSH_10.3p1")
        try await renderer.page("ssh-configuration-ready", SSHConfigurationView(request: request, snapshotMode: true))
        try await renderer.page("ssh-configuration", SSHConfigurationView(request: request, snapshotMode: true, configuration: config))
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

/// README image: the menu bar panel next to the management window, so one picture shows the whole app.
private struct Overview: View {
    static let size = CGSize(width: 1200, height: 830)

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(red: 1.0, green: 0.82, blue: 0.62), Color(red: 0.56, green: 0.6, blue: 0.72)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            HStack {
                Spacer()
                Image(nsImage: MenuBarIcon.active).renderingMode(.template)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
                    .padding(.trailing, 190)
            }
            .frame(width: Self.size.width, height: 26)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.7))
            window(ManageView(snapshotMode: true).frame(width: 800, height: 732)).offset(x: 32, y: 66)
            window(MenuContent().fixedSize()).offset(x: 856, y: 32)
        }
    }

    private func window<V: View>(_ content: V) -> some View {
        content
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.black.opacity(0.15)))
            .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
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

    /// Drive AppKit's field editor in the same isolated process; no real app state or SSH is used.
    func checkPortEditing(rule: ForwardRule, other: ForwardRule) async throws {
        navigation.show(rule.id)
        let host = NSHostingView(rootView: ManageView(snapshotMode: true)
            .environmentObject(manager).environmentObject(navigation).environment(\.locale, L10n.locale))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close(); navigation.drafts[rule.id] = nil; navigation.show(rule.id) }
        try await Task.sleep(nanoseconds: 250_000_000)
        host.layoutSubtreeIfNeeded()
        guard let field = textFields(in: host).first(where: { $0.stringValue == "8080" }) else {
            throw SnapshotCheck.failed("Port text field not found")
        }
        for value in ["", "invalid", "65536", "8081"] {
            window.makeFirstResponder(field)
            guard let editor = field.currentEditor() as? NSTextView else { throw SnapshotCheck.failed("No field editor") }
            editor.selectAll(nil)
            editor.insertText(value, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
            editor.didChangeText()
            window.makeFirstResponder(nil)
            try await Task.sleep(nanoseconds: 100_000_000)
            guard navigation.drafts[rule.id]?.ports[rule.forwards[0].id]?.bind == value else {
                throw SnapshotCheck.failed("Port input was not preserved: \(value)")
            }
        }
        navigation.show(other.id)
        try await Task.sleep(nanoseconds: 100_000_000)
        navigation.show(rule.id)
        try await Task.sleep(nanoseconds: 100_000_000)
        guard textFields(in: host).contains(where: { $0.stringValue == "8081" }) else {
            throw SnapshotCheck.failed("Port draft was lost when switching rules")
        }
        print("Isolated port editing and draft restoration passed")
    }

    private enum SnapshotCheck: Error { case failed(String) }

    func checkImportPresentation(directory: URL) async throws {
        var received: [ForwardRule]?
        let host = NSHostingView(rootView: RuleTransferMenu(snapshotMode: true, snapshotPreview: { received = $0 })
            .environmentObject(manager).environmentObject(navigation).environment(\.locale, L10n.locale))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 540),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(nanoseconds: 250_000_000)
        for index in 1...2 {
            let rules = (0..<index).map { ForwardRule(name: "Import \(index)-\($0)", host: "devbox", forwards: [PortForward()]) }
            let url = directory.appendingPathComponent("import-\(index).json")
            try RuleArchive.export(rules, to: url)
            received = nil
            NotificationCenter.default.post(name: Snapshot.importPreviewRequested, object: url)
            for _ in 0..<50 {
                if received != nil { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            guard received == rules, let sheet = window.attachedSheet else {
                throw SnapshotCheck.failed("Import \(index) did not present the selected archive")
            }
            // Exercise the actual preview's Cancel shortcut before opening a different file.
            sheet.makeKey()
            let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                          windowNumber: sheet.windowNumber, context: nil,
                                          characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                          isARepeat: false, keyCode: 53)!
            sheet.sendEvent(escape)
            for _ in 0..<50 {
                if window.attachedSheet == nil { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            guard window.attachedSheet == nil else { throw SnapshotCheck.failed("Import preview did not dismiss") }
        }
        guard manager.rules.isEmpty else { throw SnapshotCheck.failed("Cancelling import changed saved rules") }
        print("Isolated first import, cancel, and subsequent import presentation passed")
    }

    func checkQuitProtection(rule: ForwardRule) {
        let delegate = AppDelegate(manager: manager, navigation: navigation)
        assert(delegate.applicationShouldTerminate(NSApp) == .terminateNow)
        var draft = RuleDraft(rule: rule)
        draft.rule.name += " Draft"
        navigation.drafts[rule.id] = draft
        defer { navigation.drafts[rule.id] = nil }
        answerQuitPrompt(.alertFirstButtonReturn)
        assert(delegate.applicationShouldTerminate(NSApp) == .terminateCancel)
        assert(navigation.drafts[rule.id] == draft && manager.runner(id: rule.id)?.state == .running)
        answerQuitPrompt(.alertSecondButtonReturn)
        assert(delegate.applicationShouldTerminate(NSApp) == .terminateNow)
        print("Isolated quit cancellation and discard checks passed")
    }

    private func answerQuitPrompt(_ response: NSApplication.ModalResponse) {
        // The native alert runs a nested modal loop, which does not drain the main dispatch queue.
        let timer = Timer(timeInterval: 0.2, repeats: false) { _ in NSApp.stopModal(withCode: response) }
        RunLoop.main.add(timer, forMode: .modalPanel)
    }

    func quitPrompt(names: [String]) throws {
        let alert = QuitConfirmation.alert(ruleNames: names)
        alert.icon = NSImage(contentsOfFile: "Resources/AppIcon.icns")
        alert.layout()
        guard let view = alert.window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw SnapshotCheck.failed("Quit prompt could not be rendered")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        // NSVisualEffectView caches with a transparent background; flatten it for a readable PNG.
        alert.window.effectiveAppearance.performAsCurrentDrawingAppearance {
            context.cgContext.setBlendMode(.destinationOver)
            context.cgContext.setFillColor(NSColor.windowBackgroundColor.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
        }
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw SnapshotCheck.failed("Quit prompt PNG could not be encoded")
        }
        try png.write(to: output.appendingPathComponent("quit-unsaved.png"))
        print("quit-unsaved.png")
    }

    private func textFields(in view: NSView) -> [NSTextField] {
        ((view as? NSTextField).map { [$0] } ?? []) + view.subviews.flatMap { textFields(in: $0) }
    }

    func page<V: View>(_ name: String, _ view: V, size: CGSize? = nil, scale: CGFloat = 1) async throws {
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
        try save(name, host, scale: scale)
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
                try save("\(name)-scroll-\(index)", host, scale: scale)
            }
        }
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
    }

    /// The offscreen window renders at 1x; `scale` draws into a larger bitmap so README images stay sharp.
    private func save<V: View>(_ name: String, _ host: NSHostingView<V>, scale: CGFloat) throws {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(host.bounds.width * scale),
                                            pixelsHigh: Int(host.bounds.height * scale), bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { throw CocoaError(.fileWriteUnknown) }
        bitmap.size = host.bounds.size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: output.appendingPathComponent("\(name).png"))
        print("\(name).png")
    }
}
#endif
