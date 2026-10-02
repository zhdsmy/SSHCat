import Foundation

public enum AppLanguage: String, CaseIterable, Sendable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"

    /// Language names stay readable even when the current UI language is unfamiliar.
    public var displayName: String {
        switch self {
        case .system: return L10n.text("language.system")
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        }
    }
}

/// Foundation-only access to the same resource catalogs from the UI, errors and notifications.
/// Configure once before creating the app; settings changes take effect on the next launch.
public enum L10n {
    private final class Selection: @unchecked Sendable {
        let lock = NSLock()
        var language: AppLanguage = .system
    }
    private static let selection = Selection()

    // A distributed .app keeps the SwiftPM bundle inside Contents/Resources. Bundle.module's
    // generated fallback is also needed by swift run and the test runner.
    static let resourceBundle: Bundle = {
        if let url = Bundle.main.url(forResource: "SSHCat_SSHCatCore", withExtension: "bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return .module
    }()

    private static let bundles: [AppLanguage: Bundle] = Dictionary(uniqueKeysWithValues:
        AppLanguage.allCases.filter { $0 != .system }.map { language in
            // SwiftPM toolchains differ in whether they lowercase script identifiers on disk.
            let identifier = resourceBundle.localizations.first {
                $0.caseInsensitiveCompare(language.rawValue) == .orderedSame
            } ?? language.rawValue
            guard let url = resourceBundle.url(forResource: identifier, withExtension: "lproj"),
                  let bundle = Bundle(url: url) else {
                preconditionFailure("Missing localization resources: \(language.rawValue)")
            }
            return (language, bundle)
        }
    )

    public static func configure(_ language: AppLanguage) {
        selection.lock.withLock { selection.language = language }
    }

    public static var locale: Locale {
        Locale(identifier: resolve(selection.lock.withLock { selection.language }).rawValue)
    }

    public static func text(_ key: String, _ arguments: CVarArg...) -> String {
        localized(key, language: selection.lock.withLock { selection.language }, arguments: arguments)
    }

    public static func core(_ key: String, _ arguments: CVarArg...) -> String {
        localized(key, table: "Core", language: selection.lock.withLock { selection.language }, arguments: arguments)
    }

    static func resolve(_ language: AppLanguage, preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        guard language == .system else { return language }
        let available = AppLanguage.allCases.filter { $0 != .system }.map(\.rawValue)
        let preferred = Bundle.preferredLocalizations(from: available, forPreferences: preferredLanguages).first
        return preferred.flatMap(AppLanguage.init(rawValue:)) ?? .english
    }

    /// An explicit language makes catalog checks independent of the host and saved preferences.
    static func localized(_ key: String, table: String = "Localizable", language: AppLanguage,
                          preferredLanguages: [String] = Locale.preferredLanguages,
                          arguments: [CVarArg] = []) -> String {
        let language = resolve(language, preferredLanguages: preferredLanguages)
        let fallback = bundles[.english]!.localizedString(forKey: key, value: key, table: table)
        let template = bundles[language]!.localizedString(forKey: key, value: fallback, table: table)
        guard !arguments.isEmpty else { return template }
        // Integer placeholders also carry port numbers: locale formatting would insert separators.
        return String(format: template, arguments: arguments)
    }
}
