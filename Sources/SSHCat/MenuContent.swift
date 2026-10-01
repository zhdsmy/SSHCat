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
                Text("\(manager.runners.filter { $0.state == .running }.count) / \(manager.runners.count) 运行中")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
            if manager.binaryPath == nil {
                Text("找不到 ssh，请在设置中指定路径。")
                    .font(.caption).foregroundStyle(.red).padding(.horizontal, 12).padding(.bottom, 8)
            }
            if manager.loadError != nil || manager.saveError != nil {
                Button { show(nil) } label: {
                    Label("配置读写失败，打开管理窗口查看", systemImage: "exclamationmark.triangle")
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
                    Button("管理…") { show(nil) }
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
                    } label: { Label("使用说明", systemImage: "questionmark.circle") }
                    .buttonStyle(.link)
                    Spacer()
                    SettingsButton()
                    Button("退出") { NSApp.terminate(nil) }
                        .help("退出 SSHCat 并停止所有由它启动的转发")
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 12)
        }
        .frame(width: 340)
    }

    private var rulesContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            if manager.runners.isEmpty {
                Text("还没有转发。新建本地、远程转发或 SOCKS 代理，填写 SSH 主机后即可连接。")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(12)
            }
            ForEach(manager.runners) { runner in
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
                Text(incomplete ? "配置未完成，点名称继续编辑" : runner.rule.destination)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help(runner.rule.destination)
                if !incomplete {
                    Text(runner.state.label)
                        .font(.caption).foregroundStyle(runner.state.color).lineLimit(2)
                        .help(runner.state.reason ?? runner.state.label)
                }
                if hasDraft {
                    Text("有未保存的修改").font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 4)
            if let endpoint = localEndpoints {
                CopyButton(text: endpoint, label: "复制本地地址", iconOnly: true)
                    .buttonStyle(.borderless)
            }
            Toggle("运行 \(runner.rule.name)", isOn: Binding(
                get: { runner.state.isActive },
                set: { manager.setActive($0, id: runner.id) }
            ))
            .labelsHidden().toggleStyle(.switch).controlSize(.small)
            .disabled((incomplete || hasDraft) && !runner.state.isActive)
            .help(hasDraft && !runner.state.isActive ? "先在管理窗口保存修改" : "启动或停止这条转发")
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
