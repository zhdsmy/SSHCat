import AppKit
import ServiceManagement
import SwiftUI
import SSHCatCore
@preconcurrency import UserNotifications

enum UpdateStatus: Equatable {
    case checking, upToDate, available(String), failed(String)
}

struct SettingsView: View {
    @EnvironmentObject var manager: ForwardManager
    @ViewState private var settings: AppSettings
    private let snapshotMode: Bool
    @ViewState private var path: String = ""
    @ViewState private var pathError: String?
    @ViewState private var agentPath = ""
    @ViewState private var agentError: String?
    @ViewState private var notes = true
    @ViewState private var language: AppLanguage = .system
    @ViewState private var launchAtLogin = false
    @ViewState private var loginError: String?
    @ViewState private var update: UpdateStatus?
    @ViewState private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @ViewState private var loginStatus: SMAppService.Status = .notRegistered

    init(settings: AppSettings = AppSettings(), snapshotMode: Bool = false, update: UpdateStatus? = nil,
         notificationStatus: UNAuthorizationStatus = .notDetermined, loginStatus: SMAppService.Status = .notRegistered) {
        _settings = State(initialValue: settings)
        _update = State(initialValue: update)
        _notificationStatus = State(initialValue: notificationStatus)
        _loginStatus = State(initialValue: loginStatus)
        _launchAtLogin = State(initialValue: loginStatus == .enabled || loginStatus == .requiresApproval)
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
                HStack {
                    TextField(L10n.text("settings.agent_path"), text: $agentPath,
                              prompt: Text(L10n.text("settings.agent_default")))
                        .font(.system(.body, design: .monospaced)).help(agentPath).onSubmit(applyAgent)
                    Button(L10n.text("action.apply"), action: applyAgent)
                        .disabled(agentPath == (settings.identityAgent ?? ""))
                }
                if let agentError { Text(agentError).font(.caption).foregroundStyle(.red) }
                if !snapshotMode, let agent = settings.identityAgent, !FileManager.default.fileExists(atPath: agent) {
                    Text(L10n.text("settings.agent_missing")).font(.caption).foregroundStyle(.orange)
                }
                Text(L10n.text("settings.agent_hint")).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                VStack(alignment: .leading, spacing: 6) {
                    Text(notificationPermissionText).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(L10n.text("settings.system_settings")) {
                        guard !snapshotMode else { return }
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                    }.buttonStyle(.link)
                }
                if notificationStatus == .notDetermined {
                    Button(L10n.text("settings.allow_notifications")) { Task { await requestNotifications() } }
                        .disabled(snapshotMode || !notes)
                }
                Toggle(L10n.text("settings.login"), isOn: $launchAtLogin)
                if loginStatus == .requiresApproval {
                    Text(L10n.text("settings.login_pending")).font(.caption).foregroundStyle(.orange)
                    Button(L10n.text("settings.system_settings")) {
                        if !snapshotMode { SMAppService.openSystemSettingsLoginItems() }
                    }.buttonStyle(.link)
                } else if loginStatus == .notFound {
                    Text(L10n.text("settings.login_unavailable")).font(.caption).foregroundStyle(.secondary)
                }
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
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
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
        agentPath = settings.identityAgent ?? ""
        agentError = nil
        notes = settings.notificationsEnabled
        language = settings.language
        refreshPermissions()
    }

    private var notificationPermissionText: String {
        switch notificationStatus {
        case .authorized, .provisional, .ephemeral: return L10n.text("settings.notifications_allowed")
        case .denied: return L10n.text("settings.notifications_denied")
        case .notDetermined: return L10n.text("settings.notifications_pending")
        @unknown default: return L10n.text("settings.notifications_pending")
        }
    }

    private func refreshPermissions() {
        guard !snapshotMode else { return }
        loginStatus = SMAppService.mainApp.status
        launchAtLogin = loginStatus == .enabled || loginStatus == .requiresApproval
        Task {
            notificationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        }
    }

    private func requestNotifications() async {
        guard !snapshotMode else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        refreshPermissions()
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
        let status = SMAppService.mainApp.status
        let currentlyEnabled = status == .enabled || status == .requiresApproval
        guard enabled != currentlyEnabled else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
            refreshPermissions()
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

    private func applyAgent() {
        do {
            let value = try AppSettings.validatedIdentityAgent(agentPath)
            settings.identityAgent = value
            agentPath = value ?? ""
            agentError = nil
            if !snapshotMode { manager.objectWillChange.send() }
        } catch {
            agentError = error.localizedDescription
        }
    }
}
