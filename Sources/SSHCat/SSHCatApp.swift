import AppKit
import Combine
import SwiftUI
import SSHCatCore
@preconcurrency import UserNotifications

@main
struct SSHCatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(delegate.manager)
                .environmentObject(delegate.navigation)
        } label: {
            Image(nsImage: menuIcon)
        }
        .menuBarExtraStyle(.window)

        Window("SSHCat", id: "manage") {
            ManageView()
                .environmentObject(delegate.manager)
                .environmentObject(delegate.navigation)
        }
        .defaultSize(width: 880, height: 640)
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView().environmentObject(delegate.manager)
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
    /// Unsaved edits by rule. Kept here, not in the editor, so switching rules or closing the
    /// window does not throw them away.
    @Published var drafts: [UUID: RuleDraft] = [:]
}

struct RuleDraft: Equatable {
    var rule: ForwardRule
    /// The port field as typed; it may not parse yet.
    var portText: String
}

/// Owns the one `ForwardManager` the scenes display.
///
/// `App.init` runs before SwiftUI installs `@StateObject` storage. Creating the manager here,
/// in the delegate, keeps the menu and the window on the same instance.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject, UNUserNotificationCenterDelegate {
    let manager = ForwardManager()
    let navigation = Navigation()
    private var runnerObserver: AnyCancellable?

    override init() {
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
