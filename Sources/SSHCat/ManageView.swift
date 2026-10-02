import AppKit
import SwiftUI
import SSHCatCore

struct ManageView: View {
    @EnvironmentObject var manager: ForwardManager
    @EnvironmentObject var navigation: Navigation
    @ViewState private var hosts: [String] = []
    var snapshotMode = false

    var body: some View {
        VStack(spacing: 0) {
            StorageNotice()
            NavigationSplitView {
                VStack(spacing: 0) {
                    TextField(L10n.text("manage.search"), text: $navigation.searchText)
                        .textFieldStyle(.roundedBorder).padding(10)
                    RuleFilterPicker().padding(.horizontal, 10).padding(.bottom, 6)
                    List(selection: $navigation.selection) {
                        ForEach(visibleRunners) { runner in
                            SidebarRow(runner: runner, unsaved: navigation.drafts[runner.id] != nil)
                                .tag(runner.id)
                        }
                        if visibleRunners.isEmpty && !manager.runners.isEmpty {
                            Text(L10n.text("manage.no_matches")).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .listStyle(.sidebar)
                    Divider()
                    Button {
                        navigation.selection = nil
                        navigation.showingGuide = true
                    } label: {
                        Label(L10n.text("action.guide"), systemImage: "questionmark.circle")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain).padding(12)
                }
                .navigationSplitViewColumnWidth(min: 200, ideal: 230)
                .background(SplitSeamAlign())
                .toolbar {
                    ToolbarItem {
                        NewRuleMenu { navigation.add($0, using: manager) }
                            .disabled(!manager.canEditRules)
                    }
                    ToolbarItem { RuleTransferMenu(snapshotMode: snapshotMode) }
                }
            } detail: {
                detail.frame(minWidth: 480)
            }
        }
        .frame(minWidth: 740, minHeight: 500)
        .onAppear { if !snapshotMode { hosts = SSHConfigHosts.load() } }
        .onChange(of: navigation.selection) { id in
            if id != nil { navigation.showingGuide = false }
        }
    }

    private var visibleRunners: [ForwardRunner] {
        manager.runners.filter { navigation.filter.includes($0.state) && $0.rule.matches(navigation.searchText) }
    }

    @ViewBuilder private var detail: some View {
        if navigation.showingGuide || manager.runners.isEmpty {
            UsageGuide()
        } else if let id = navigation.selection, let runner = manager.runner(id: id) {
            RuleEditor(runner: runner, hosts: $hosts, saved: navigation.drafts[id], snapshotMode: snapshotMode)
                .id(runner.id)
        } else {
            VStack(spacing: 16) {
                Image(systemName: "network").font(.system(size: 36)).foregroundStyle(.secondary)
                Text(L10n.text("manage.title")).font(.title2.weight(.semibold))
                Text(L10n.text("manage.select_rule"))
                    .foregroundStyle(.secondary)
                NewRuleMenu { navigation.add($0, using: manager) }
                    .disabled(!manager.canEditRules)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
        }
    }
}

private struct SidebarRow: View {
    @ObservedObject var runner: ForwardRunner
    let unsaved: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            StatusDot(state: runner.state).padding(.top, 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(runner.rule.name).fontWeight(.medium).lineLimit(1).help(runner.rule.name)
                Text(runner.rule.destination.isEmpty ? L10n.text("manage.host_pending") : runner.rule.destination)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help(runner.rule.destination)
                Text(unsaved ? L10n.text("manage.unsaved_state", runner.state.label) : runner.state.label)
                    .font(.caption).foregroundStyle(unsaved ? .orange : runner.state.color)
                    .lineLimit(1).help(runner.state.reason ?? runner.state.label)
            }
        }
        .padding(.vertical, 3)
    }
}

/// Hides the 1pt split divider line and lines the detail title-bar background up with it.
///
/// AppKit starts the detail column's title-bar background (`NSTitlebarBackgroundView`) at the
/// divider's 4pt hit area, left of where the detail column starts, so the sidebar edge jogs at the title bar.
/// Both views are private and AppKit re-lays them out on every resize, so we correct the background
/// whenever its frame changes and keep its right edge on the title bar's right edge.
private struct SplitSeamAlign: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        SeamAlignView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class SeamAlignView: NSView {
    private var observers: [NSObjectProtocol] = []
    private weak var line: NSView?
    private weak var background: NSView?
    private var backgroundObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window else { return }
        let realign: (Notification) -> Void = { [weak self] _ in self?.align() }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: window, queue: .main, using: realign))
        observers.append(NotificationCenter.default.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification, object: nil, queue: .main, using: realign))
        scheduleAlign()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
    }

    override func layout() {
        super.layout()
        scheduleAlign()
    }

    /// The title bar is laid out after the split view on first show, so also try on the next turn.
    private func scheduleAlign() {
        align()
        DispatchQueue.main.async { [weak self] in self?.align() }
    }

    private func align() {
        guard let window else { return }
        var root: NSView? = window.contentView
        while let parent = root?.superview { root = parent }
        guard let root,
              let divider = find(in: root, where: { $0.className == "NSVibrantSplitDividerView" }),
              let line = divider.subviews.first(where: { $0 is NSVisualEffectView }) else { return }
        self.line = line
        if line.alphaValue != 0 { line.alphaValue = 0 }

        if background?.window !== window {
            let lineX = line.convert(line.bounds, to: nil).minX
            let backgrounds = findAll(in: root) { $0.className == "NSTitlebarBackgroundView" && !$0.isHidden }
            // The detail column's background is the visible one that starts near the divider.
            guard let found = backgrounds.first(where: {
                abs($0.convert($0.bounds, to: nil).minX - lineX) < 8
            }) else { return }
            watch(found)
        }
        fitBackground()
    }

    private func watch(_ view: NSView) {
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        background = view
        view.postsFrameChangedNotifications = true
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: view, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.fitBackground() }
        }
    }

    /// Runs synchronously from the frame-change notification so live resize never shows AppKit's frame.
    private func fitBackground() {
        guard let line, let background, let superview = background.superview else { return }
        // With the line hidden, its column shows the sidebar-coloured window background, so the
        // detail column visibly starts at the line's right edge.
        let edge = line.convert(line.bounds, to: superview).maxX
        let current = background.frame
        let target = NSRect(x: edge, y: current.minY,
                            width: superview.bounds.maxX - edge, height: current.height)
        guard abs(current.minX - target.minX) > 0.25 || abs(current.width - target.width) > 0.25 else { return }
        background.frame = target
    }

    private func find(in view: NSView, where match: (NSView) -> Bool) -> NSView? {
        if match(view) { return view }
        for subview in view.subviews {
            if let found = find(in: subview, where: match) { return found }
        }
        return nil
    }

    private func findAll(in view: NSView, where match: (NSView) -> Bool) -> [NSView] {
        (match(view) ? [view] : []) + view.subviews.flatMap { findAll(in: $0, where: match) }
    }
}

private struct RuleEditor: View {
    @ObservedObject var runner: ForwardRunner
    @EnvironmentObject var manager: ForwardManager
    @EnvironmentObject var navigation: Navigation
    @Binding var hosts: [String]
    let snapshotMode: Bool

    @ViewState private var draft: ForwardRule
    @ViewState private var portText: String
    @ViewState private var ports: [UUID: RuleDraft.Ports]
    @ViewState private var choosingHost = false
    @ViewState private var confirmDelete = false
    @ViewState private var showLog = false

    /// `saved` is an unsaved draft from an earlier visit to this rule.
    init(runner: ForwardRunner, hosts: Binding<[String]>, saved: RuleDraft?, snapshotMode: Bool = false) {
        self.runner = runner
        self._hosts = hosts
        self.snapshotMode = snapshotMode
        _draft = ViewState(initialValue: saved?.rule ?? runner.rule)
        _portText = ViewState(initialValue: saved?.portText ?? runner.rule.port.map(String.init) ?? "")
        _ports = ViewState(initialValue: (saved ?? RuleDraft(rule: runner.rule)).ports)
        _confirmDelete = ViewState(initialValue: false)
    }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if runner.state.reason != nil {
                        StateDetail(state: runner.state)
                        firstConnectionButton
                    }
                    GroupBox { targetSection.padding(8) }
                    GroupBox { forwardsSection.padding(8) }
                    GroupBox { runSection.padding(8) }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onChange(of: draft) { _ in keepDraft() }
        .onChange(of: portText) { _ in keepDraft() }
        .onChange(of: ports) { _ in keepDraft() }
        .onChange(of: runner.rule) { rule in
            // A reload may replace saved settings; keep real edits, refresh an untouched editor.
            guard navigation.drafts[runner.id] == nil else { return }
            draft = rule
            portText = rule.port.map(String.init) ?? ""
            ports = RuleDraft(rule: rule).ports
        }
        .confirmationDialog(L10n.text("editor.confirm_delete"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(L10n.text("action.delete"), role: .destructive) {
                let id = runner.id
                guard manager.remove(id: id) else { return }
                navigation.selection = nil
                navigation.drafts[id] = nil
            }
            Button(L10n.text("action.cancel"), role: .cancel) {}
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField(L10n.text("editor.name"), text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                    .font(.title2)
                    .accessibilityLabel(L10n.text("editor.name_accessibility"))
                Menu {
                    Button(L10n.text("action.copy_rule")) {
                        let copy = runner.rule.duplicate()
                        guard manager.add(copy) else { return }
                        navigation.show(copy.id)
                    }
                    .disabled(isDirty || !manager.canEditRules)
                    Divider()
                    Button(L10n.text("action.delete_rule"), role: .destructive) { confirmDelete = true }
                        .disabled(!manager.canEditRules)
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
                .help(L10n.text("action.more")).accessibilityLabel(L10n.text("action.more"))
            }
            FieldError(issue: editing.issue(for: .name))
            HStack {
                StatusDot(state: runner.state)
                Text(runner.state.label).font(.callout).lineLimit(1)
                    .help(runner.state.reason ?? runner.state.label)
                Spacer()
                Toggle(L10n.text("action.run"), isOn: Binding(
                    get: { runner.state.isActive },
                    set: { manager.setActive($0, id: runner.id) }
                ))
                .toggleStyle(.switch)
                // The toggle runs the saved rule; starting it with edits pending would run stale settings.
                .disabled((isDirty || parsedRule == nil) && !runner.state.isActive)
                .help(isDirty && !runner.state.isActive ? L10n.text("editor.save_first") : "")
                Button(L10n.text("action.save")) { save() }
                    .disabled(saveDisabled || !manager.canEditRules)
                    .keyboardShortcut("s", modifiers: .command)
            }
            HStack {
                if !runner.state.isActive && (runner.state == .stopped || isDirty) {
                    Button(L10n.text("action.save_connect")) { save(connect: true) }
                        .disabled(parsedRule == nil || !manager.canEditRules)
                } else if runner.state.reason != nil {
                    Button(L10n.text("action.retry")) { manager.retry(id: runner.id) }
                        .disabled(isDirty)
                }
                if let issue = editing.issues.first?.issue {
                    Text(L10n.text("editor.fix_fields")).font(.caption).foregroundStyle(.red)
                        .help(issue.localizedDescription)
                }
            }
            if isDirty {
                HStack(spacing: 8) {
                    Text(runner.state.isActive ? L10n.text("editor.unsaved_active") : L10n.text("editor.unsaved"))
                    Button(L10n.text("action.revert"), action: revert).buttonStyle(.link)
                }
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
    }

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("editor.target")).font(.headline)
            LabeledContent(L10n.text("editor.host")) {
                HStack {
                    TextField(L10n.text("editor.host_prompt"), text: $draft.host)
                        .textFieldStyle(.roundedBorder)
                    Button { choosingHost = true } label: { Image(systemName: "list.bullet") }
                        .help(L10n.text("editor.ssh_config_hosts"))
                        .accessibilityLabel(L10n.text("editor.ssh_config_hosts"))
                        .popover(isPresented: $choosingHost) {
                            HostPicker(hosts: hosts, refresh: {
                                if !snapshotMode { hosts = SSHConfigHosts.load() }
                            }, select: { draft.host = $0; choosingHost = false })
                        }
                }
            }
            FieldError(issue: editing.issue(for: .host))
            LabeledContent(L10n.text("editor.user")) {
                TextField(L10n.text("editor.config_default"), text: $draft.user).textFieldStyle(.roundedBorder)
            }
            FieldError(issue: editing.issue(for: .user))
            LabeledContent(L10n.text("editor.port")) {
                TextField(L10n.text("editor.config_default"), text: $portText).textFieldStyle(.roundedBorder)
            }
            FieldError(issue: editing.issue(for: .sshPort))
            LabeledContent(L10n.text("editor.key")) {
                HStack {
                    TextField(L10n.text("editor.key_default"), text: $draft.identityFile)
                        .textFieldStyle(.roundedBorder)
                    Button(L10n.text("action.choose_file")) { chooseIdentity() }
                }
            }
            FieldError(issue: editing.issue(for: .identity))
            Text(L10n.text("editor.config_hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var forwardsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.text("editor.forwards")).font(.headline)
                Spacer()
                Menu(L10n.text("action.add")) {
                    ForEach(ForwardKind.allCases, id: \.self) { kind in
                        Button(kind.defaultName) {
                            draft.forwards.append(PortForward(kind: kind, bindPort: kind == .dynamic ? 1080 : 8080))
                        }
                    }
                }.fixedSize()
            }
            if draft.forwards.isEmpty {
                Text(L10n.text("editor.forwards_empty")).font(.caption).foregroundStyle(.secondary)
            }
            ForEach($draft.forwards) { $forward in
                ForwardRow(forward: $forward, ports: Binding(
                    get: { editing.portDraft(forward) },
                    set: { ports[forward.id] = $0 }
                ), issues: editing.issues) {
                    draft.forwards.removeAll { $0.id == forward.id }
                    ports[forward.id] = nil
                }
            }
            let clashes = manager.listenerConflicts(in: parsedRule ?? draft)
            if !clashes.isEmpty {
                ForEach(clashes, id: \.endpoint) { conflict in
                    Text(L10n.text("editor.named_port_clash", conflict.endpoint,
                                   ListFormatter.localizedString(byJoining: conflict.ruleNames)))
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    private var runSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("action.run")).font(.headline)
            Toggle(L10n.text("editor.auto_restart"), isOn: $draft.autoRestart)
            Toggle(L10n.text("editor.auto_start"), isOn: $draft.autoStart)

            let endpoints = runner.rule.forwards.compactMap(\.localEndpoint)
            if !endpoints.isEmpty, (try? runner.rule.validate()) != nil {
                LabeledContent(L10n.text("editor.local_addresses")) {
                    Text(endpoints.joined(separator: "\n")).font(.callout.monospaced()).textSelection(.enabled)
                    CopyButton(text: endpoints.joined(separator: "\n"), label: L10n.text("action.copy_address"), iconOnly: true)
                        .buttonStyle(.borderless)
                }
            }
            Text(L10n.text("editor.running_hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
            DisclosureGroup(L10n.text("editor.command")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(commandText)
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    CopyButton(text: commandText, label: L10n.text("action.copy_command")).disabled(parsedRule == nil)
                }.padding(.top, 6)
            }
            DisclosureGroup(L10n.text("editor.log"), isExpanded: $showLog) {
                logView.padding(.top, 6)
            }
            if runner.state.reason == nil { firstConnectionButton }
            CopyButton(text: diagnostics, label: L10n.text("action.copy_diagnostics"))
        }
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(runner.log.isEmpty ? L10n.text("editor.log_empty") : runner.log.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                Color.clear.frame(height: 1).id(logEnd)
            }
            .frame(height: 200)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onAppear { proxy.scrollTo(logEnd, anchor: .bottom) }
            // Not `log.count`: it stops changing once the log reaches capacity.
            .onChange(of: runner.log) { _ in proxy.scrollTo(logEnd, anchor: .bottom) }
        }
    }

    private let logEnd = "log-end"

    @ViewBuilder private var firstConnectionButton: some View {
        if let command = try? runner.rule.firstConnectionCommand(executable: executable) {
            CopyButton(text: command, label: L10n.text("action.copy_first_connection"))
                .help(L10n.text("editor.first_connection_hint"))
        }
    }

    private var diagnostics: String {
        Diagnostics.report(
            appVersion: appVersion,
            sshVersion: manager.sshVersion,
            rule: runner.rule,
            commandLine: runner.rule.commandLine(executable: executable),
            state: [runner.state.label, runner.state.reason].compactMap { $0 }.joined(separator: " · "),
            log: runner.log
        )
    }

    private var executable: String { snapshotMode ? "/usr/bin/ssh" : manager.binaryPath ?? "/usr/bin/ssh" }

    private var commandText: String {
        guard let rule = parsedRule else { return L10n.core("rule.command_unavailable") }
        return rule.commandLine(executable: executable)
    }

    private var parsedRule: ForwardRule? {
        try? editing.validated()
    }

    private var saveDisabled: Bool {
        parsedRule == nil || !isDirty
    }

    private var savedPortText: String { runner.rule.port.map(String.init) ?? "" }

    private var editing: RuleDraft {
        var value = RuleDraft(rule: draft, portText: portText)
        value.ports = ports
        return value
    }

    private var isDirty: Bool { editing.isDirty(comparedTo: runner.rule) }

    private func keepDraft() {
        navigation.drafts[runner.id] = isDirty ? editing : nil
    }

    private func save(connect: Bool = false) {
        guard let rule = parsedRule else { return }
        guard connect ? manager.saveAndStart(rule) : manager.update(rule) else { return }
        draft = rule
        portText = savedPortText
        ports = RuleDraft(rule: runner.rule).ports
        navigation.drafts[runner.id] = nil
    }

    private func revert() {
        draft = runner.rule
        portText = savedPortText
        ports = RuleDraft(rule: runner.rule).ports
        navigation.drafts[runner.id] = nil
    }

    private func chooseIdentity() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = L10n.text("editor.choose_key")
        panel.prompt = L10n.text("action.choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.identityFile = url.path
    }
}

private struct ForwardRow: View {
    @Binding var forward: PortForward
    @Binding var ports: RuleDraft.Ports
    let issues: [(field: RuleField, issue: ForwardIssue)]
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker(L10n.text("forward.type"), selection: $forward.kind) {
                    ForEach(ForwardKind.allCases, id: \.self) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)
                Spacer()
                Button(L10n.text("action.delete"), action: onDelete)
            }
            HStack {
                Text(forward.kind == .remote ? L10n.text("forward.remote_listener") : L10n.text("forward.local_listener")).font(.caption).frame(width: 90, alignment: .leading)
                TextField(L10n.text("forward.bind_address"), text: $forward.bindAddress)
                    .textFieldStyle(.roundedBorder)
                TextField(L10n.text("editor.port"), text: $ports.bind)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
            }
            FieldError(issue: issues.first { $0.field == .bindAddress(forward.id) }?.issue)
            FieldError(issue: issues.first { $0.field == .bindPort(forward.id) }?.issue)
            if forward.kind != .dynamic {
                HStack {
                    Text(forward.kind == .local ? L10n.text("forward.remote_target") : L10n.text("forward.local_target")).font(.caption).frame(width: 90, alignment: .leading)
                    TextField(forward.kind == .local ? L10n.text("forward.remote_target_host") : L10n.text("forward.local_target_host"), text: $forward.targetHost)
                        .textFieldStyle(.roundedBorder)
                    TextField(L10n.text("editor.port"), text: $ports.target)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }
            }
            if forward.kind != .dynamic {
                FieldError(issue: issues.first { $0.field == .targetHost(forward.id) }?.issue)
                FieldError(issue: issues.first { $0.field == .targetPort(forward.id) }?.issue)
            }
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
            if forward.needsGatewayPorts {
                Text(L10n.text("forward.gateway_ports"))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var hint: String {
        switch forward.kind {
        case .local: return L10n.text("forward.local_hint")
        case .remote: return L10n.text("forward.remote_hint")
        case .dynamic: return L10n.text("forward.dynamic_hint")
        }
    }
}

struct HostPicker: View {
    let hosts: [String]
    let refresh: () -> Void
    let select: (String) -> Void
    @ViewState private var search = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField(L10n.text("hosts.search"), text: $search).textFieldStyle(.roundedBorder)
                Button(L10n.text("hosts.refresh"), action: refresh)
            }
            let matches = hosts.filter { search.isEmpty || $0.localizedStandardContains(search) }
            if matches.isEmpty {
                Text(L10n.text("hosts.empty")).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading) {
                    ForEach(matches, id: \.self) { host in
                        Button(host) { select(host) }.buttonStyle(.plain)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                    }
                }
            }
        }.padding().frame(width: 340, height: 260)
    }
}
