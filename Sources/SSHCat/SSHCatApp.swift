import AppKit
import Combine
import SwiftUI
import SSHCatCore
@preconcurrency import UserNotifications

@main
enum Entry {
    @MainActor static func main() {
        #if DEBUG
        if CommandLine.arguments.contains("--snapshot") { Snapshot.run(arguments: CommandLine.arguments) }
        #endif
        configureLanguage(AppSettings().language)
        SSHCatApp.main()
    }

    @MainActor static func configureLanguage(_ language: AppLanguage) {
        if language != .system {
            // Process-only: system dialogs use the chosen language without changing global preferences.
            var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            arguments["AppleLanguages"] = [language.rawValue]
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        }
        L10n.configure(language)
    }
}

struct SSHCatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environment(\.locale, L10n.locale)
                .environmentObject(delegate.manager)
                .environmentObject(delegate.navigation)
        } label: {
            Image(nsImage: menuIcon)
        }
        .menuBarExtraStyle(.window)

        Window("SSHCat", id: "manage") {
            ManageView()
                .environment(\.locale, L10n.locale)
                .environmentObject(delegate.manager)
                .environmentObject(delegate.navigation)
        }
        .defaultSize(width: 880, height: 640)
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView().environmentObject(delegate.manager).environment(\.locale, L10n.locale)
        }
    }

    /// Outline when idle, solid while a forward is up.
    private var menuIcon: NSImage {
        delegate.manager.runners.contains { $0.state == .running } ? MenuBarIcon.active : MenuBarIcon.idle
    }
}

/// Which rule the management window shows. Shared so the menu can jump to one.
@MainActor
final class Navigation: ObservableObject {
    @Published var selection: UUID?
    @Published var showingGuide = false
    @Published var searchText = ""
    @Published var filter: RuleFilter = .all
    /// Unsaved edits by rule. Kept here, not in the editor, so switching rules or closing the
    /// window does not throw them away.
    @Published var drafts: [UUID: RuleDraft] = [:]

    func show(_ id: UUID) {
        searchText = ""
        filter = .all
        showingGuide = false
        selection = id
    }

    func add(_ kind: ForwardKind, using manager: ForwardManager) {
        let rule = ForwardRule(name: kind.defaultName,
                               forwards: [PortForward(kind: kind, bindPort: kind == .dynamic ? 1080 : 8080)])
        guard manager.add(rule) else { return }
        show(rule.id)
    }
}

/// Owns the one `ForwardManager` the scenes display.
///
/// `App.init` runs before SwiftUI installs `@StateObject` storage. Creating the manager here,
/// in the delegate, keeps the menu and the window on the same instance.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject, UNUserNotificationCenterDelegate {
    let manager: ForwardManager
    let navigation: Navigation
    private var runnerObserver: AnyCancellable?

    override convenience init() {
        self.init(manager: ForwardManager(), navigation: Navigation())
    }

    init(manager: ForwardManager, navigation: Navigation) {
        self.manager = manager
        self.navigation = navigation
        super.init()
        runnerObserver = manager.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            NSApp.setActivationPolicy(.accessory)
            UNUserNotificationCenter.current().delegate = self
            manager.onNotify = { title, body in AppNotifications.post(title: title, body: body) }
            AppNotifications.requestAuthorizationIfNeeded()
            manager.bootstrap()
        }
    }

    nonisolated func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { manager.shutdown() }
    }

    nonisolated func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            sender.keyWindow?.makeFirstResponder(nil)
            let unsaved = manager.rules.filter { navigation.drafts[$0.id]?.isDirty(comparedTo: $0) == true }
            guard !unsaved.isEmpty else { return .terminateNow }
            let alert = QuitConfirmation.alert(ruleNames: unsaved.map(\.name))
            guard alert.runModal() == .alertSecondButtonReturn else {
                navigation.show(unsaved[0].id)
                sender.windows.first { $0.title == "SSHCat" }?.makeKeyAndOrderFront(nil)
                return .terminateCancel
            }
            return .terminateNow
        }
    }

    /// A menu bar app counts as frontmost while its window is open; show banners anyway.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

enum AppNotifications {
    static func requestAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    static func post(title: String, body: String) {
        guard AppSettings().notificationsEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
