import AppKit
import SwiftUI
import SSHCatCore

extension RunState {
    /// One line for lists. The countdown and full reason live in `StateDetail`, which can refresh.
    var label: String {
        switch self {
        case .stopped: return "已停止"
        case .starting: return "连接中…"
        case .running: return "运行中"
        case .reconnecting(let attempt, _, _): return "重连中（第 \(attempt) 次）"
        case .failed(let reason): return "失败：\(reason)"
        }
    }

    /// Why the last session ended, when there is one to show.
    var reason: String? {
        switch self {
        case .reconnecting(_, _, let reason), .failed(let reason): return reason
        case .stopped, .starting, .running: return nil
        }
    }

    var color: Color {
        switch self {
        case .running: return .green
        case .starting, .reconnecting: return .orange
        case .failed: return .red
        case .stopped: return Color.secondary
        }
    }
}

struct StatusDot: View {
    let state: RunState
    var body: some View {
        Circle().fill(state.color).frame(width: 9, height: 9)
            .accessibilityLabel(state.label)
    }
}

struct NewRuleMenu: View {
    let action: (ForwardKind) -> Void

    var body: some View {
        Menu {
            Button("本地转发 · 访问远端服务") { action(.local) }
            Button("远程转发 · 分享本机服务") { action(.remote) }
            Button("SOCKS 代理 · 动态转发") { action(.dynamic) }
        } label: {
            Label("新建转发", systemImage: "plus")
        }
    }
}

struct SettingsButton: View {
    var body: some View {
        Group {
            if #available(macOS 14, *) {
                SettingsLink { Image(systemName: "gearshape") }
            } else {
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                } label: { Image(systemName: "gearshape") }
            }
        }
        .help("设置").accessibilityLabel("设置")
    }
}

struct StorageNotice: View {
    @EnvironmentObject var manager: ForwardManager

    var body: some View {
        if manager.loadError != nil || manager.saveError != nil {
            VStack(alignment: .leading, spacing: 6) {
                if let error = manager.loadError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .fixedSize(horizontal: false, vertical: true)
                    Button("重新加载配置") { manager.reloadRules() }
                }
                if let error = manager.saveError {
                    Label("保存失败：\(error)", systemImage: "exclamationmark.triangle")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("修改尚未应用。检查文件权限和可用空间后，请重试刚才的操作。")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout).foregroundStyle(.red).textSelection(.enabled)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.06))
        }
    }
}

struct CopyButton: View {
    let text: String
    var label = "复制"
    var iconOnly = false
    @ViewState private var copied = false

    var body: some View {
        Button {
            Clipboard.copy(text)
            copied = true
        } label: {
            if iconOnly {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            } else {
                Label(copied ? "已复制" : label, systemImage: copied ? "checkmark" : "doc.on.doc")
            }
        }
        .help(copied ? "已复制" : label)
        .accessibilityLabel(copied ? "已复制" : label)
        .task(id: copied) {
            guard copied else { return }
            do { try await Task.sleep(nanoseconds: 1_500_000_000) } catch { return }
            copied = false
        }
    }
}

/// State with a live retry countdown, plus the reason ssh gave and what to do about it.
struct StateDetail: View {
    let state: RunState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch state {
            case .reconnecting(let attempt, let retryAt, _):
                // `.timer` redraws itself; a string computed once would freeze at its first value.
                (Text("重连中（第 \(attempt) 次），") + Text(retryAt, style: .timer) + Text(" 后重试"))
                    .foregroundStyle(.orange)
            case .failed:
                Text("已失败，不会自动重连。修正后重新打开规则。").foregroundStyle(.red)
            default:
                EmptyView()
            }
            if let reason = state.reason {
                Text(reason)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                if let hint = SSHFailure.hint(for: reason) {
                    Text(hint).foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum Clipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

var appVersion: String {
    let info = Bundle.main.infoDictionary
    let short = info?["CFBundleShortVersionString"] as? String ?? "开发版"
    let build = info?["CFBundleVersion"] as? String
    return build.map { "\(short) (\($0))" } ?? short
}
