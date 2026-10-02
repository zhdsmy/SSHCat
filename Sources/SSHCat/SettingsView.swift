import AppKit
import ServiceManagement
import SwiftUI
import SSHCatCore

enum UpdateStatus: Equatable {
    case checking, upToDate, available(String), failed(String)
}

struct SettingsView: View {
    @EnvironmentObject var manager: ForwardManager
    @ViewState private var settings: AppSettings
    private let snapshotMode: Bool
    @ViewState private var path: String = ""
    @ViewState private var pathError: String?
    @ViewState private var notes = true
    @ViewState private var language: AppLanguage = .system
    @ViewState private var launchAtLogin = false
    @ViewState private var loginError: String?
    @ViewState private var update: UpdateStatus?

    init(settings: AppSettings = AppSettings(), snapshotMode: Bool = false, update: UpdateStatus? = nil) {
        _settings = State(initialValue: settings)
        _update = State(initialValue: update)
        self.snapshotMode = snapshotMode
    }

    var body: some View {
        Form {
            Section("SSH") {
                HStack {
                    TextField(L10n.text("settings.custom_path"), text: $path, prompt: Text(L10n.text("settings.path_default")))
                        .font(.system(.body, design: .monospaced))
                        .onSubmit(applyPath)
                    Button(L10n.text("action.apply"), action: applyPath)
                        .disabled(trimmedPath == (settings.customBinaryPath ?? ""))
                }
                if let pathError {
                    Text(pathError).font(.caption).foregroundStyle(.red)
                }
                LabeledContent(L10n.text("settings.current_binary")) {
                    Text(displayedBinaryPath ?? L10n.text("settings.binary_missing"))
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(displayedBinaryPath ?? "")
                }
                LabeledContent(L10n.text("settings.version")) {
                    Text(displayedSSHVersion ?? "—").textSelection(.enabled)
                }
                Text(L10n.text("settings.path_hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section(L10n.text("settings.general")) {
                Picker(L10n.text("language.label"), selection: $language) {
                    ForEach(AppLanguage.allCases, id: \.self) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                Text(L10n.text("language.restart_hint"))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(L10n.text("settings.notifications"), isOn: $notes)
                Toggle(L10n.text("settings.login"), isOn: $launchAtLogin)
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                Text(L10n.text("settings.login_hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section(L10n.text("settings.updates")) {
                LabeledContent(L10n.text("settings.current_version")) {
                    Text(appVersion).font(.system(.body, design: .monospaced))
                }
                Link(L10n.text("settings.download"), destination: UpdateCheck.releasesPage)
                HStack {
                    Button(L10n.text("settings.check_updates")) { Task { await checkForUpdate() } }
                        .disabled(snapshotMode || update == .checking)
                    switch update {
                    case .checking?: ProgressView(L10n.text("settings.checking")).controlSize(.small)
                    case .upToDate?: Text(L10n.text("settings.up_to_date")).foregroundStyle(.secondary)
                    case .available(let version)?: Text(L10n.text("settings.update_available", version))
                    case .failed(let message)?:
                        Text(L10n.text("settings.check_failed", message)).foregroundStyle(.red).lineLimit(2).help(message)
                    case nil: Text(L10n.text("settings.unchecked")).foregroundStyle(.secondary)
                    }
                }
                Text(L10n.text("settings.update_hint"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 520, height: 680)
        .onAppear {
            load()
            if !snapshotMode { manager.refreshBinary() }
        }
        .onChange(of: notes) { newValue in
            settings.notificationsEnabled = newValue
        }
        .onChange(of: language) { newValue in
            settings.language = newValue
        }
        .onChange(of: launchAtLogin) { newValue in
            setLaunchAtLogin(newValue)
        }
    }

    private var trimmedPath: String { path.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var displayedBinaryPath: String? { snapshotMode ? "/usr/bin/ssh" : manager.binaryPath }
    private var displayedSSHVersion: String? { snapshotMode ? "OpenSSH_example" : manager.sshVersion }

    private func load() {
        path = settings.customBinaryPath ?? ""
        pathError = nil
        notes = settings.notificationsEnabled
        language = settings.language
        if !snapshotMode { launchAtLogin = SMAppService.mainApp.status == .enabled }
    }

    private func checkForUpdate() async {
        update = .checking
        do {
            let newer = try await UpdateCheck.newerRelease(than: appVersion)
            update = newer.map(UpdateStatus.available) ?? .upToDate
        } catch {
            update = .failed(error.localizedDescription)
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        guard !snapshotMode else { return }
        let currentlyEnabled = SMAppService.mainApp.status == .enabled
        guard enabled != currentlyEnabled else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
            launchAtLogin = currentlyEnabled
        }
    }

    /// Applied on Return or the button, not per keystroke: a half-typed path would otherwise be
    /// saved and silently fall back to /usr/bin/ssh.
    private func applyPath() {
        let value = trimmedPath
        if !value.isEmpty, !FileManager.default.isExecutableFile(atPath: value) {
            pathError = L10n.text("settings.path_invalid", value)
            return
        }
        pathError = nil
        settings.customBinaryPath = value
        if !snapshotMode { manager.refreshBinary() }
    }
}
