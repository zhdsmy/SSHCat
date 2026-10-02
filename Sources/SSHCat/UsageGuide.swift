import SwiftUI
import SSHCatCore

struct UsageGuide: View {
    @EnvironmentObject var manager: ForwardManager
    @EnvironmentObject var navigation: Navigation

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Label(L10n.text("guide.title"), systemImage: "network")
                    .font(.title2.weight(.semibold))
                Text(L10n.text("guide.introduction"))
                    .foregroundStyle(.secondary)
                GroupBox(L10n.text("guide.scenarios")) {
                    VStack(alignment: .leading, spacing: 16) {
                        scenario(L10n.text("guide.local_title"), example: L10n.text("guide.local_example"), kind: .local,
                                 detail: L10n.text("guide.local_detail"))
                        Divider()
                        scenario(L10n.text("guide.remote_title"), example: L10n.text("guide.remote_example"), kind: .remote,
                                 detail: L10n.text("guide.remote_detail"))
                        Divider()
                        scenario(L10n.text("guide.dynamic_title"), example: L10n.text("guide.dynamic_example"), kind: .dynamic,
                                 detail: L10n.text("guide.dynamic_detail"))
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox(L10n.text("guide.first_connection")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L10n.text("guide.first_connection_detail"))
                        Text(L10n.text("guide.ssh_config"))
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox(L10n.text("guide.troubleshooting")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L10n.text("guide.failure"))
                        Text(L10n.text("guide.retry"))
                        Text(L10n.text("guide.unreachable"))
                        Text(L10n.text("guide.diagnostics"))
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 640, alignment: .leading).padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func scenario(_ title: String, example: String, kind: ForwardKind, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button(L10n.text("action.create")) { navigation.add(kind, using: manager) }
                    .disabled(!manager.canEditRules).accessibilityLabel(L10n.text("guide.create_scenario", title))
            }
            Text(example).font(.callout.monospaced())
            Text(detail).font(.callout).foregroundStyle(.secondary)
        }
    }
}
