import AppKit
import SwiftUI
import UniformTypeIdentifiers
import SSHCatCore

struct RuleTransferMenu: View {
    @EnvironmentObject var manager: ForwardManager
    @EnvironmentObject var navigation: Navigation
    var snapshotMode = false
    private struct PendingImport: Identifiable {
        let id = UUID()
        let rules: [ForwardRule]
    }
    @ViewState private var incoming: PendingImport?
    @ViewState private var error: String?
    #if DEBUG
    var snapshotPreview: (([ForwardRule]) -> Void)?
    #endif

    var body: some View {
        Menu {
            Button(L10n.text("transfer.import"), action: importFile).disabled(!manager.canEditRules)
            Button(L10n.text("transfer.export_selected")) {
                if let rule = manager.runner(id: navigation.selection)?.rule { export([rule]) }
            }.disabled(navigation.selection == nil || navigation.selection.map { navigation.drafts[$0] != nil } == true)
            Button(L10n.text("transfer.export_all")) { export(manager.rules) }
                .disabled(manager.rules.isEmpty)
        } label: { Label(L10n.text("transfer.title"), systemImage: "square.and.arrow.up") }
        .disabled(snapshotMode)
        .sheet(item: $incoming) { item in
            #if DEBUG
            ImportPreview(rules: item.rules, snapshotPresented: snapshotMode ? snapshotPreview : nil)
            #else
            ImportPreview(rules: item.rules)
            #endif
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: Snapshot.importPreviewRequested)) { notification in
            if snapshotMode, let url = notification.object as? URL { loadPreview(from: url) }
        }
        #endif
        .alert(L10n.text("transfer.error"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(L10n.text("action.close")) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func importFile() {
        guard !snapshotMode else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadPreview(from: url)
    }

    private func loadPreview(from url: URL) {
        do { incoming = PendingImport(rules: try RuleArchive.read(url)) }
        catch { self.error = error.localizedDescription }
    }

    private func export(_ rules: [ForwardRule]) {
        guard !snapshotMode else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "SSHCat-rules.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try RuleArchive.export(rules, to: url) }
        catch { self.error = error.localizedDescription }
    }
}

struct ImportPreview: View {
    @EnvironmentObject var manager: ForwardManager
    @Environment(\.dismiss) private var dismiss
    let rules: [ForwardRule]
    @ViewState private var duplicates: RuleArchive.Duplicates = .skip
    #if DEBUG
    var snapshotPresented: (([ForwardRule]) -> Void)?
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("transfer.preview")).font(.title2.weight(.semibold))
            Text(L10n.text("transfer.hint")).foregroundStyle(.secondary)
            Picker(L10n.text("transfer.duplicates"), selection: $duplicates) {
                Text(L10n.text("transfer.skip")).tag(RuleArchive.Duplicates.skip)
                Text(L10n.text("transfer.copy")).tag(RuleArchive.Duplicates.copy)
            }
            let repeated = RuleArchive.duplicateIndices(rules, existing: manager.rules)
            let count = duplicates == .skip ? rules.count - repeated.count : rules.count
            Text(L10n.text("transfer.count", count, rules.count))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(rules.enumerated()), id: \.offset) { index, rule in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(rule.name).fontWeight(.medium)
                                Spacer()
                                Text(repeated.contains(index)
                                     ? (duplicates == .skip ? L10n.text("transfer.skipped") : L10n.text("transfer.copied"))
                                     : L10n.text("transfer.added"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text(rule.destination).font(.callout.monospaced())
                            Text(rule.forwards.map(\.summary).joined(separator: "\n"))
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                        }.textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error = manager.saveError { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button(L10n.text("action.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.text("transfer.confirm")) {
                    if manager.importRules(rules, duplicates: duplicates) { dismiss() }
                }.disabled(count == 0 || !manager.canEditRules).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 560, height: 460)
        #if DEBUG
        .onAppear { snapshotPresented?(rules) }
        #endif
    }
}
