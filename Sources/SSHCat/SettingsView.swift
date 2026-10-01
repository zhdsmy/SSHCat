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
                    TextField("自定义路径", text: $path, prompt: Text("留空使用 /usr/bin/ssh"))
                        .font(.system(.body, design: .monospaced))
                        .onSubmit(applyPath)
                    Button("应用", action: applyPath)
                        .disabled(trimmedPath == (settings.customBinaryPath ?? ""))
                }
                if let pathError {
                    Text(pathError).font(.caption).foregroundStyle(.red)
                }
                LabeledContent("当前使用") {
                    Text(displayedBinaryPath ?? "找不到可执行的 ssh")
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(displayedBinaryPath ?? "")
                }
                LabeledContent("版本") {
                    Text(displayedSSHVersion ?? "—").textSelection(.enabled)
                }
                Text("从 Finder 打开时 PATH 里没有 Homebrew，要用其他 ssh 需要写绝对路径。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("通用") {
                Toggle("失败和重连时通知", isOn: $notes)
                Toggle("登录时启动", isOn: $launchAtLogin)
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                Text("登录项需要从“应用程序”里的 SSHCat.app 打开才会生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("SSHCat 更新") {
                LabeledContent("当前版本") {
                    Text(appVersion).font(.system(.body, design: .monospaced))
                }
                Link("打开 GitHub 下载页", destination: UpdateCheck.releasesPage)
                HStack {
                    Button("检查更新") { Task { await checkForUpdate() } }
                        .disabled(snapshotMode || update == .checking)
                    switch update {
                    case .checking?: ProgressView("正在检查…").controlSize(.small)
                    case .upToDate?: Text("已是最新版本").foregroundStyle(.secondary)
                    case .available(let version)?: Text("发现新版本：\(version)")
                    case .failed(let message)?:
                        Text("检查失败：\(message)").foregroundStyle(.red).lineLimit(2).help(message)
                    case nil: Text("尚未检查").foregroundStyle(.secondary)
                    }
                }
                Text("仅在点击时访问 GitHub 查询最新版本。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 520, height: 600)
        .onAppear {
            load()
            if !snapshotMode { manager.refreshBinary() }
        }
        .onChange(of: notes) { newValue in
            settings.notificationsEnabled = newValue
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
            pathError = "\(value) 不存在或不可执行，没有保存。"
            return
        }
        pathError = nil
        settings.customBinaryPath = value
        if !snapshotMode { manager.refreshBinary() }
    }
}
