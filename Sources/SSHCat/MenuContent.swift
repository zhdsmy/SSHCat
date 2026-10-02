import AppKit
import SwiftUI
import SSHCatCore

struct MenuContent: View {
    @EnvironmentObject var manager: ForwardManager
    @EnvironmentObject var navigation: Navigation
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("SSHCat").font(.headline)
                Spacer()
                Text(L10n.text("menu.running_count", manager.runners.filter { $0.state == .running }.count, manager.runners.count))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
            if !manager.runners.isEmpty { RuleFilterPicker().padding(.horizontal, 12).padding(.bottom, 8) }
            if manager.binaryPath == nil {
                Text(L10n.text("menu.binary_missing"))
                    .font(.caption).foregroundStyle(.red).padding(.horizontal, 12).padding(.bottom, 8)
            }
            if manager.loadError != nil || manager.saveError != nil {
                Button { show(nil) } label: {
                    Label(L10n.text("menu.storage_failed"), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(.plain).padding(.horizontal, 12).padding(.bottom, 8)
            }
            ViewThatFits(in: .vertical) {
                rulesContent.fixedSize(horizontal: false, vertical: true)
                ScrollView { rulesContent }
            }
            .frame(maxHeight: 440)
            Divider().padding(.vertical, 8)
            VStack(spacing: 10) {
                HStack {
                    Button(L10n.text("action.manage")) { show(nil) }
                    NewRuleMenu { kind in
                        navigation.add(kind, using: manager)
                        show(nil)
                    }
                    .disabled(!manager.canEditRules)
                    Spacer(minLength: 0)
                }
                HStack {
                    Button {
                        navigation.showingGuide = true
                        show(nil)
                    } label: { Label(L10n.text("action.guide"), systemImage: "questionmark.circle") }
                    .buttonStyle(.link)
                    Spacer()
                    SettingsButton()
                    Button(L10n.text("action.quit")) { NSApp.terminate(nil) }
                        .help(L10n.text("action.quit_help"))
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 12)
        }
        .frame(width: 340)
    }

    private var rulesContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            if manager.runners.isEmpty {
                Text(L10n.text("menu.empty"))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(12)
            }
            let visible = manager.runners.filter { navigation.filter.includes($0.state) }
            if visible.isEmpty && !manager.runners.isEmpty {
                Text(L10n.text("manage.no_matches")).font(.callout).foregroundStyle(.secondary).padding(12)
            }
            ForEach(visible) { runner in
                MenuRow(runner: runner) { show(runner.id) }
            }
        }
    }

    private func show(_ id: UUID?) {
        if let id { navigation.show(id) }
        openWindow(id: "manage")
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct MenuRow: View {
    @EnvironmentObject var manager: ForwardManager
    @EnvironmentObject var navigation: Navigation
    @ObservedObject var runner: ForwardRunner
    let onOpen: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            StatusDot(state: runner.state).padding(.top, 4)
            VStack(alignment: .leading, spacing: 3) {
                Button(runner.rule.name, action: onOpen)
                    .buttonStyle(.plain).font(.body.weight(.medium))
                    .lineLimit(1).help(runner.rule.name)
                Text(incomplete ? L10n.text("menu.incomplete") : runner.rule.destination)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help(runner.rule.destination)
                if !incomplete {
                    Text(runner.rule.forwards.map(\.summary).joined(separator: " · "))
                        .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        .help(runner.rule.forwards.map(\.summary).joined(separator: "\n"))
                    Text(runner.state.label)
                        .font(.caption).foregroundStyle(runner.state.color).lineLimit(2)
                        .help(runner.state.reason ?? runner.state.label)
                }
                if hasDraft {
                    Text(L10n.text("menu.unsaved")).font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 4)
            if runner.state.reason != nil {
                Button { manager.retry(id: runner.id) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).disabled(hasDraft || incomplete)
                    .help(L10n.text("action.retry")).accessibilityLabel(L10n.text("action.retry"))
            }
            if let endpoint = localEndpoints {
                CopyButton(text: endpoint, label: L10n.text("action.copy_address"), iconOnly: true)
                    .buttonStyle(.borderless)
            }
            Toggle(L10n.text("menu.run_rule", runner.rule.name), isOn: Binding(
                get: { runner.state.isActive },
                set: { manager.setActive($0, id: runner.id) }
            ))
            .labelsHidden().toggleStyle(.switch).controlSize(.small)
            .disabled((incomplete || hasDraft) && !runner.state.isActive)
            .help(hasDraft && !runner.state.isActive ? L10n.text("menu.save_first") : L10n.text("menu.toggle_help"))
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
    }

    private var hasDraft: Bool { navigation.drafts[runner.id] != nil }
    private var incomplete: Bool { (try? runner.rule.validate()) == nil }
    private var localEndpoints: String? {
        let lines = runner.rule.forwards.compactMap(\.localEndpoint)
        return incomplete || lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
