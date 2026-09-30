import AppKit
import ServiceManagement
import SwiftUI
import SSHCatCore

struct SettingsView: View {
    @EnvironmentObject var manager: ForwardManager
    @ViewState private var path: String = ""
    @ViewState private var pathError: String?
    @ViewState private var notes = true
    @ViewState private var launchAtLogin = false
    @ViewState private var loginError: String?

    var body: some View {
        Form {
            Section("ssh") {
                HStack {
                    TextField("自定义路径", text: $path, prompt: Text("留空使用 /usr/bin/ssh"))
                        .onSubmit(applyPath)
                    Button("应用", action: applyPath)
                        .disabled(trimmedPath == (AppSettings().customBinaryPath ?? ""))
                }
                if let pathError {
                    Text(pathError).font(.caption).foregroundStyle(.red)
                }
                LabeledContent("当前使用") {
                    Text(manager.binaryPath ?? "找不到可执行的 ssh")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                LabeledContent("版本") {
                    Text(manager.sshVersion ?? "—").textSelection(.enabled)
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
            Section {
                LabeledContent("SSHCat", value: appVersion)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .onAppear {
            path = AppSettings().customBinaryPath ?? ""
            pathError = nil
            notes = AppSettings().notificationsEnabled
            launchAtLogin = SMAppService.mainApp.status == .enabled
            manager.refreshBinary()
        }
        .onChange(of: notes) { newValue in
            AppSettings().notificationsEnabled = newValue
        }
        .onChange(of: launchAtLogin) { newValue in
            // onAppear writes the current status into the toggle; don't register again then.
            let enabled = SMAppService.mainApp.status == .enabled
            guard newValue != enabled else { return }
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                loginError = nil
            } catch {
                loginError = error.localizedDescription
                launchAtLogin = enabled
            }
        }
    }

    private var trimmedPath: String { path.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Applied on Return or the button, not per keystroke: a half-typed path would otherwise be
    /// saved and silently fall back to /usr/bin/ssh.
    private func applyPath() {
        let value = trimmedPath
        if !value.isEmpty, !FileManager.default.isExecutableFile(atPath: value) {
            pathError = "\(value) 不存在或不可执行，没有保存。"
            return
        }
        pathError = nil
        AppSettings().customBinaryPath = value
        manager.refreshBinary()
    }
}
