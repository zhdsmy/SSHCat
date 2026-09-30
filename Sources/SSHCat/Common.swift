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
