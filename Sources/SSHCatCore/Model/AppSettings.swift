import Foundation

/// UserDefaults-backed preferences. An explicit suite so a `swift run` binary and the bundled
/// app share the same settings.
public struct AppSettings: @unchecked Sendable {
    public static let suiteName = "io.github.zhdsmy.SSHCat"

    public enum Key {
        public static let customBinaryPath = "customBinaryPath"
        public static let notificationsEnabled = "notificationsEnabled"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = UserDefaults(suiteName: AppSettings.suiteName) ?? .standard) {
        self.defaults = defaults
    }

    public var customBinaryPath: String? {
        get {
            let v = defaults.string(forKey: Key.customBinaryPath) ?? ""
            return v.isEmpty ? nil : v
        }
        nonmutating set {
            if let newValue, !newValue.isEmpty {
                defaults.set(newValue, forKey: Key.customBinaryPath)
            } else {
                defaults.removeObject(forKey: Key.customBinaryPath)
            }
        }
    }

    /// Defaults to on; first launch has no key, so treat missing as true.
    public var notificationsEnabled: Bool {
        get {
            if defaults.object(forKey: Key.notificationsEnabled) == nil { return true }
            return defaults.bool(forKey: Key.notificationsEnabled)
        }
        nonmutating set { defaults.set(newValue, forKey: Key.notificationsEnabled) }
    }
}
