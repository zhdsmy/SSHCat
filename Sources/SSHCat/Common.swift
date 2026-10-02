import AppKit
import SwiftUI
import SSHCatCore

extension RunState {
    /// One line for lists. The countdown and full reason live in `StateDetail`, which can refresh.
    var label: String {
        switch self {
        case .stopped: return L10n.text("state.stopped")
        case .starting: return L10n.text("state.starting")
        case .running: return L10n.text("state.running")
        case .reconnecting(let attempt, _, _): return L10n.text("state.reconnecting", attempt)
        case .failed(let reason): return L10n.text("state.failed", reason)
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
            Button(L10n.text("action.new_local")) { action(.local) }
            Button(L10n.text("action.new_remote")) { action(.remote) }
            Button(L10n.text("action.new_dynamic")) { action(.dynamic) }
        } label: {
            Label(L10n.text("action.new_forward"), systemImage: "plus")
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
        .help(L10n.text("action.settings")).accessibilityLabel(L10n.text("action.settings"))
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
                    Button(L10n.text("action.reload")) { manager.reloadRules() }
                }
                if let error = manager.saveError {
                    Label(L10n.text("storage.save_failed", error), systemImage: "exclamationmark.triangle")
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L10n.text("storage.retry_hint"))
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
    var label = L10n.text("action.copy")
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
                Label(copied ? L10n.text("action.copied") : label, systemImage: copied ? "checkmark" : "doc.on.doc")
            }
        }
        .help(copied ? L10n.text("action.copied") : label)
        .accessibilityLabel(copied ? L10n.text("action.copied") : label)
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
                // Keep the entire sentence localizable while refreshing the countdown.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(L10n.text("state.retry_countdown", attempt,
                                   max(0, Int(retryAt.timeIntervalSince(context.date).rounded(.up)))))
                        .foregroundStyle(.orange)
                }
            case .failed:
                Text(L10n.text("state.failed_hint")).foregroundStyle(.red)
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
    let short = info?["CFBundleShortVersionString"] as? String ?? L10n.text("app.development_version")
    let build = info?["CFBundleVersion"] as? String
    return build.map { "\(short) (\($0))" } ?? short
}
