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
                    TextField("搜索名称、主机或端口", text: $navigation.searchText)
                        .textFieldStyle(.roundedBorder).padding(10)
                    List(selection: $navigation.selection) {
                        ForEach(manager.runners.filter { $0.rule.matches(navigation.searchText) }) { runner in
                            SidebarRow(runner: runner, unsaved: navigation.drafts[runner.id] != nil)
                                .tag(runner.id)
                        }
                        if !navigation.searchText.isEmpty,
                           !manager.runners.contains(where: { $0.rule.matches(navigation.searchText) }) {
                            Text("没有匹配的转发").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .listStyle(.sidebar)
                    Divider()
                    Button {
                        navigation.selection = nil
                        navigation.showingGuide = true
                    } label: {
                        Label("使用说明", systemImage: "questionmark.circle")
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

    @ViewBuilder private var detail: some View {
        if navigation.showingGuide || manager.runners.isEmpty {
            UsageGuide()
        } else if let id = navigation.selection, let runner = manager.runner(id: id) {
            RuleEditor(runner: runner, hosts: hosts, saved: navigation.drafts[id], snapshotMode: snapshotMode)
                .id(runner.id)
        } else {
            VStack(spacing: 16) {
                Image(systemName: "network").font(.system(size: 36)).foregroundStyle(.secondary)
                Text("管理你的 SSH 转发").font(.title2.weight(.semibold))
                Text("从左侧选择规则，查看连接状态或修改配置。")
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
                Text(runner.rule.destination.isEmpty ? "等待配置主机" : runner.rule.destination)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help(runner.rule.destination)
                Text(unsaved ? "未保存 · \(runner.state.label)" : runner.state.label)
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
    let hosts: [String]
    let snapshotMode: Bool

    @ViewState private var draft: ForwardRule
    @ViewState private var portText: String
    @ViewState private var confirmDelete = false
    @ViewState private var showLog = false

    /// `saved` is an unsaved draft from an earlier visit to this rule.
    init(runner: ForwardRunner, hosts: [String], saved: RuleDraft?, snapshotMode: Bool = false) {
        self.runner = runner
        self.hosts = hosts
        self.snapshotMode = snapshotMode
        _draft = ViewState(initialValue: saved?.rule ?? runner.rule)
        _portText = ViewState(initialValue: saved?.portText ?? runner.rule.port.map(String.init) ?? "")
        _confirmDelete = ViewState(initialValue: false)
    }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if runner.state.reason != nil { StateDetail(state: runner.state) }
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
        .onChange(of: runner.rule) { rule in
            // A reload may replace saved settings; keep real edits, refresh an untouched editor.
            guard navigation.drafts[runner.id] == nil else { return }
            draft = rule
            portText = rule.port.map(String.init) ?? ""
        }
        .confirmationDialog("删除这条转发？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                let id = runner.id
                guard manager.remove(id: id) else { return }
                navigation.selection = nil
                navigation.drafts[id] = nil
            }
            Button("取消", role: .cancel) {}
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("名称", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                    .font(.title2)
                    .accessibilityLabel("转发名称")
                Menu {
                    Button("创建副本") {
                        let copy = runner.rule.duplicate()
                        guard manager.add(copy) else { return }
                        navigation.show(copy.id)
                    }
                    .disabled(isDirty || !manager.canEditRules)
                    Divider()
                    Button("删除转发…", role: .destructive) { confirmDelete = true }
                        .disabled(!manager.canEditRules)
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
                .help("更多操作").accessibilityLabel("更多操作")
            }
            HStack {
                StatusDot(state: runner.state)
                Text(runner.state.label).font(.callout).lineLimit(1)
                    .help(runner.state.reason ?? runner.state.label)
                Spacer()
                Toggle("运行", isOn: Binding(
                    get: { runner.state.isActive },
                    set: { manager.setActive($0, id: runner.id) }
                ))
                .toggleStyle(.switch)
                // The toggle runs the saved rule; starting it with edits pending would run stale settings.
                .disabled((isDirty || parsedRule == nil) && !runner.state.isActive)
                .help(isDirty && !runner.state.isActive ? "有未保存的修改，先保存再运行" : "")
                Button("保存", action: save)
                    .disabled(saveDisabled || !manager.canEditRules)
                    .keyboardShortcut("s", modifiers: .command)
            }
            if isDirty {
                HStack(spacing: 8) {
                    Text(runner.state.isActive ? "有未保存的修改。保存连接参数后会重启。" : "有未保存的修改。")
                    Button("还原", action: revert).buttonStyle(.link)
                }
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
    }

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("目标").font(.headline)
            LabeledContent("主机") {
                HStack {
                    TextField("SSH Host 或主机名", text: $draft.host)
                        .textFieldStyle(.roundedBorder)
                    if !hosts.isEmpty {
                        Menu {
                            ForEach(hosts, id: \.self) { host in
                                Button(host) { draft.host = host }
                            }
                        } label: { Image(systemName: "list.bullet") }
                        .fixedSize().help("从 SSH 配置选择").accessibilityLabel("从 SSH 配置选择")
                    }
                }
            }
            LabeledContent("用户") {
                TextField("留空使用 SSH 配置", text: $draft.user).textFieldStyle(.roundedBorder)
            }
            LabeledContent("端口") {
                TextField("留空使用 SSH 配置", text: $portText).textFieldStyle(.roundedBorder)
            }
            LabeledContent("密钥") {
                HStack {
                    TextField("留空使用 SSH 配置或 agent", text: $draft.identityFile)
                        .textFieldStyle(.roundedBorder)
                    Button("选择…") { chooseIdentity() }
                }
            }
            Text("端口和密钥留空时，ssh 会使用这个 Host 在配置里的 Port、IdentityFile 和 ProxyJump。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var forwardsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("转发").font(.headline)
                Spacer()
                Menu("添加") {
                    ForEach(ForwardKind.allCases, id: \.self) { kind in
                        Button(kind == .dynamic ? "SOCKS 代理" : "\(kind.label)转发") {
                            draft.forwards.append(PortForward(kind: kind, bindPort: kind == .dynamic ? 1080 : 8080))
                        }
                    }
                }.fixedSize()
            }
            if draft.forwards.isEmpty {
                Text("至少需要一条转发。").font(.caption).foregroundStyle(.secondary)
            }
            ForEach($draft.forwards) { $forward in
                ForwardRow(forward: $forward) {
                    draft.forwards.removeAll { $0.id == forward.id }
                }
            }
            let clashes = manager.clashingEndpoints(in: draft)
            if !clashes.isEmpty {
                Text("本机 \(clashes.joined(separator: "、")) 已被其他规则或本规则的另一条转发使用，同时运行时会有一方失败。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var runSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("运行").font(.headline)
            Toggle("意外退出后自动重连", isOn: $draft.autoRestart)
            Toggle("打开 App 时自动启动", isOn: $draft.autoStart)
            if case .failure(let issue) = parsed() {
                Text(issue.localizedDescription).foregroundStyle(.red).font(.callout)
            }
            let endpoints = runner.rule.forwards.compactMap(\.localEndpoint)
            if !endpoints.isEmpty, (try? runner.rule.validate()) != nil {
                LabeledContent("本地地址") {
                    Text(endpoints.joined(separator: "\n")).font(.callout.monospaced()).textSelection(.enabled)
                    CopyButton(text: endpoints.joined(separator: "\n"), label: "复制本地地址", iconOnly: true)
                        .buttonStyle(.borderless)
                }
            }
            Text("“运行中”表示 SSH 会话已建立；访问服务还需确认目标端口可用。")
                .font(.caption)
                .foregroundStyle(.secondary)
            DisclosureGroup("等价命令") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(commandText)
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    CopyButton(text: commandText, label: "复制命令").disabled(parsedRule == nil)
                }.padding(.top, 6)
            }
            DisclosureGroup("连接日志", isExpanded: $showLog) {
                logView.padding(.top, 6)
            }
            CopyButton(text: diagnostics, label: "复制诊断信息")
        }
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(runner.log.isEmpty ? "还没有输出" : runner.log.joined(separator: "\n"))
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
        guard let rule = parsedRule else { return "配置还不完整，无法生成命令" }
        return rule.commandLine(executable: executable)
    }

    private var parsedRule: ForwardRule? {
        if case .success(let rule) = parsed() { return rule }
        return nil
    }

    private var saveDisabled: Bool {
        guard let rule = parsedRule else { return true }
        return rule == runner.rule
    }

    private var savedPortText: String { runner.rule.port.map(String.init) ?? "" }

    private var isDirty: Bool { draft != runner.rule || portText != savedPortText }

    private func keepDraft() {
        navigation.drafts[runner.id] = isDirty ? RuleDraft(rule: draft, portText: portText) : nil
    }

    private func save() {
        guard let rule = parsedRule else { return }
        guard manager.update(rule) else { return }
        draft = rule
        portText = savedPortText
        navigation.drafts[runner.id] = nil
    }

    private func revert() {
        draft = runner.rule
        portText = savedPortText
        navigation.drafts[runner.id] = nil
    }

    private func parsed() -> Result<ForwardRule, ForwardIssue> {
        var rule = draft
        rule.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        rule.user = draft.user.trimmingCharacters(in: .whitespacesAndNewlines)
        rule.host = draft.host.trimmingCharacters(in: .whitespacesAndNewlines)
        rule.identityFile = draft.identityFile.trimmingCharacters(in: .whitespacesAndNewlines)
        for index in rule.forwards.indices {
            rule.forwards[index].bindAddress = rule.forwards[index].bindAddress
                .trimmingCharacters(in: .whitespacesAndNewlines)
            rule.forwards[index].targetHost = rule.forwards[index].targetHost
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let trimmedPort = portText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedPort.isEmpty {
            rule.port = nil
        } else if let port = Int(trimmedPort), (1...65535).contains(port) {
            rule.port = port
        } else {
            return .failure(.invalidPort)
        }
        do {
            try rule.validate()
            return .success(rule)
        } catch let issue as ForwardIssue {
            return .failure(issue)
        } catch {
            return .failure(.emptyName)
        }
    }

    private func chooseIdentity() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = "选择私钥文件"
        panel.prompt = "选择"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.identityFile = url.path
    }
}

private struct ForwardRow: View {
    @Binding var forward: PortForward
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("类型", selection: $forward.kind) {
                    ForEach(ForwardKind.allCases, id: \.self) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)
                Spacer()
                Button("删除", action: onDelete)
            }
            HStack {
                Text(forward.kind == .remote ? "远端监听" : "本机监听").font(.caption).frame(width: 60, alignment: .leading)
                TextField("绑定地址", text: $forward.bindAddress)
                    .textFieldStyle(.roundedBorder)
                TextField("端口", value: $forward.bindPort, format: IntegerFormatStyle<Int>().grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
            }
            if forward.kind != .dynamic {
                HStack {
                    Text(forward.kind == .local ? "远端目标" : "本机目标").font(.caption).frame(width: 60, alignment: .leading)
                    TextField(forward.kind == .local ? "远端目标主机" : "本机目标主机", text: $forward.targetHost)
                        .textFieldStyle(.roundedBorder)
                    TextField("端口", value: $forward.targetPort, format: IntegerFormatStyle<Int>().grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }
            }
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
            if forward.needsGatewayPorts {
                Text("绑定地址不是回环。远程转发要在服务器上监听这个地址，sshd 需要打开 GatewayPorts。")
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
        case .local: return "本机绑定地址:端口 → SSH 服务器能访问的目标"
        case .remote: return "SSH 服务器上的绑定地址:端口 → 本机目标"
        case .dynamic: return "本机 SOCKS 代理"
        }
    }
}
