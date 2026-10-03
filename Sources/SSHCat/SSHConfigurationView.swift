import SwiftUI
import SSHCatCore

struct SSHConfigurationRequest: Identifiable {
    let id = UUID()
    let rule: ForwardRule
    let executable: URL
    let identityAgent: String?
    var knownHostsFile: String?
    var hostKeyRemovalCommand: String?
    var sshVersion: String?
}

struct SSHConfigurationView: View {
    let request: SSHConfigurationRequest
    var snapshotMode = false
    @Environment(\.dismiss) private var dismiss
    @ViewState private var configuration: SSHConfiguration?
    @ViewState private var error: String?
    @ViewState private var loading = false
    @ViewState private var reads = 0

    init(request: SSHConfigurationRequest, snapshotMode: Bool = false, configuration: SSHConfiguration? = nil) {
        self.request = request
        self.snapshotMode = snapshotMode
        _configuration = ViewState(initialValue: configuration)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.text("configuration.title")).font(.headline)
                Spacer()
                Button(L10n.text("action.done")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(request.rule.destination).font(.callout.monospaced()).textSelection(.enabled)
            Text(L10n.text("configuration.exec_warning")).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button { reads += 1 } label: {
                    Label(L10n.text("configuration.read"), systemImage: "arrow.clockwise")
                }.disabled(loading || snapshotMode)
                if loading { ProgressView().controlSize(.small) }
                Spacer()
                if let configuration {
                    CopyButton(text: report(configuration), label: L10n.text("configuration.copy"))
                }
            }.frame(height: 28)
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            Divider()
            ScrollView {
                if let configuration {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(fields, id: \.0) { key, label in
                            if let values = configuration.values[key] {
                                LabeledContent(label) {
                                    Text(values.joined(separator: "\n")).font(.callout.monospaced()).textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        if configuration.hasAdditionalForwards(comparedTo: request.rule) {
                            Label(L10n.text("configuration.extra_forwards"), systemImage: "exclamationmark.triangle")
                                .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        }
                        if request.rule.forwards.contains(where: { $0.kind == .remoteDynamic }),
                           !SSHCapabilities(version: request.sshVersion).supportsPermitRemoteOpen {
                            Text(L10n.text("configuration.permit_remote_open_version")).font(.callout).foregroundStyle(.orange)
                        }
                        if let command = request.hostKeyRemovalCommand ?? request.knownHostsFile.flatMap({ configuration.hostKeyRemovalCommand(knownHostsFile: $0) }) {
                            Divider()
                            Text(L10n.text("configuration.verify_fingerprint")).font(.callout).foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(command).font(.callout.monospaced()).textSelection(.enabled)
                            CopyButton(text: command, label: L10n.text("configuration.copy_key_removal"))
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(20).frame(width: 680, height: 560)
        .task(id: reads) {
            guard reads > 0, !snapshotMode else { return }
            loading = true
            error = nil
            defer { loading = false }
            do {
                configuration = try await SSHConfiguration.inspect(executable: request.executable, rule: request.rule,
                                                                   identityAgent: request.identityAgent)
            } catch is CancellationError {
            } catch {
                configuration = nil
                self.error = error.localizedDescription
            }
        }
    }

    private var fields: [(String, String)] {
        [("hostname", L10n.text("configuration.hostname")), ("user", L10n.text("editor.user")),
         ("port", L10n.text("editor.port")), ("proxyjump", "ProxyJump"), ("proxycommand", "ProxyCommand"), ("identityfile", "IdentityFile"),
         ("identityagent", "IdentityAgent"), ("hostkeyalias", "HostKeyAlias"), ("userknownhostsfile", "UserKnownHostsFile"),
         ("localforward", "LocalForward"), ("remoteforward", "RemoteForward"), ("dynamicforward", "DynamicForward"),
         ("permitremoteopen", "PermitRemoteOpen"), ("clearallforwardings", "ClearAllForwardings")]
    }

    private func report(_ configuration: SSHConfiguration) -> String {
        fields.flatMap { key, _ in configuration.values[key, default: []].map { "\(key) \($0)" } }.joined(separator: "\n")
    }
}
