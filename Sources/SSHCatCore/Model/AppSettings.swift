import Foundation

/// UserDefaults-backed preferences. An explicit suite so a `swift run` binary and the bundled
/// app share the same settings.
public struct AppSettings: @unchecked Sendable {
    public static let suiteName = "io.github.zhdsmy.SSHCat"

    public enum Key {
        public static let customBinaryPath = "customBinaryPath"
        public static let notificationsEnabled = "notificationsEnabled"
        public static let language = "language"
        public static let identityAgent = "identityAgent"
    }

    /// An unset override preserves each Host's IdentityAgent and the inherited environment.
    public var identityAgent: String? {
        get { defaults.string(forKey: Key.identityAgent).flatMap { $0.isEmpty ? nil : $0 } }
        nonmutating set {
            let value = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if value.isEmpty { defaults.removeObject(forKey: Key.identityAgent) }
            else { defaults.set(value, forKey: Key.identityAgent) }
        }
    }

    public static func validatedIdentityAgent(_ raw: String?) throws -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        guard !SSHToken.containsControl(raw) else { throw ForwardIssue.invalidAgent }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return nil }
        guard value.hasPrefix("/") else { throw ForwardIssue.invalidAgent }
        return value
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

    /// Existing installations follow the system until the user chooses a language.
    public var language: AppLanguage {
        get { defaults.string(forKey: Key.language).flatMap(AppLanguage.init(rawValue:)) ?? .system }
        nonmutating set {
            if newValue == .system { defaults.removeObject(forKey: Key.language) }
            else { defaults.set(newValue.rawValue, forKey: Key.language) }
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
