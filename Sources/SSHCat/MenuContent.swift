import AppKit
import SwiftUI
import SSHCatCore

struct MenuContent: View {
    @EnvironmentObject var manager: ForwardManager
    @EnvironmentObject var navigation: Navigation
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if manager.binaryPath == nil {
                Text("找不到 ssh。请先安装，或在设置里指定路径。")
                    .font(.callout)
                    .padding(12)
            }
            if manager.runners.isEmpty {
                Text("还没有转发，点“管理…”新建").foregroundStyle(.secondary).padding(12)
            }
            ForEach(manager.runners) { runner in
                MenuRow(runner: runner) { show(runner.id) }
            }
            Divider().padding(.vertical, 4)
            HStack {
                Button("管理…") { show(nil) }
                Spacer()
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                } label: { Image(systemName: "gearshape") }
                    .help("设置")
                Button("退出") { NSApp.terminate(nil) }
            }
            .padding(.horizontal, 12).padding(.bottom, 8)
        }
        .frame(width: 340)
    }

    private func show(_ id: UUID?) {
        if let id { navigation.selection = id }
        openWindow(id: "manage")
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct MenuRow: View {
    @EnvironmentObject var manager: ForwardManager
    @ObservedObject var runner: ForwardRunner
    let onOpen: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            StatusDot(state: runner.state).padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Button(runner.rule.name, action: onOpen)
                    .buttonStyle(.plain)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            if let endpoint = localEndpoints {
                Button {
                    Clipboard.copy(endpoint)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("复制本地地址")
            }
            Toggle("", isOn: Binding(
                get: { runner.state.isActive },
                set: { manager.setActive($0, id: runner.id) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(incomplete && !runner.state.isActive)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    /// A new rule is saved before its host is filled in; starting it could only fail.
    private var incomplete: Bool { (try? runner.rule.validate()) == nil }

    private var subtitle: String {
        if incomplete { return "配置还不完整，点名称去编辑" }
        let dest = runner.rule.destination
        let maps = runner.rule.forwards.map(\.summary).joined(separator: "，")
        if maps.isEmpty { return dest }
        return "\(dest) · \(maps)"
    }

    private var localEndpoints: String? {
        let lines = runner.rule.forwards.compactMap(\.localEndpoint)
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
