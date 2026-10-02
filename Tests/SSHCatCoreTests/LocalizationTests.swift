import Foundation
import Testing
@testable import SSHCatCore

@Suite struct LocalizationTests {
    @Test func languageSelectionUsesScriptAndRegion() {
        for preferences in [["en-US"], ["en-GB"], ["fr-FR"]] {
            #expect(L10n.resolve(.system, preferredLanguages: preferences) == .english)
        }
        for preferences in [["zh-CN"], ["zh-SG"], ["zh-Hans"]] {
            #expect(L10n.resolve(.system, preferredLanguages: preferences) == .simplifiedChinese)
        }
        for preferences in [["zh-TW"], ["zh-HK"], ["zh-Hant"], ["fr-FR", "zh-TW"]] {
            #expect(L10n.resolve(.system, preferredLanguages: preferences) == .traditionalChinese)
        }
        #expect(L10n.resolve(.english, preferredLanguages: ["zh-TW"]) == .english)
        #expect(L10n.resolve(.traditionalChinese, preferredLanguages: ["en-US"]) == .traditionalChinese)
    }

    @Test func catalogsHaveMatchingKeysAndFormatArguments() throws {
        for table in ["Core", "Localizable"] {
            let english = try catalog(.english, table: table)
            #expect(!english.isEmpty)
            for language in AppLanguage.allCases where language != .system {
                let translated = try catalog(language, table: table)
                #expect(Set(translated.keys) == Set(english.keys), "\(language.rawValue)/\(table)")
                for (key, value) in english {
                    let translation = try #require(translated[key], "\(language.rawValue)/\(key)")
                    #expect(!translation.isEmpty, "\(language.rawValue)/\(key)")
                    #expect(try placeholders(value) == placeholders(translation), "\(language.rawValue)/\(key)")
                    #expect(L10n.localized(key, table: table, language: language) == translation)
                }
            }
        }
        #expect(L10n.localized("missing.key", language: .traditionalChinese) == "missing.key")
    }

    @Test func sourceKeysExistInCatalogs() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let files = try #require(FileManager.default.enumerator(at: root.appendingPathComponent("Sources"),
                                                               includingPropertiesForKeys: nil))
        let catalogs = ["core": try catalog(.english, table: "Core"),
                        "text": try catalog(.english, table: "Localizable")]
        let pattern = try NSRegularExpression(pattern: #"L10n\.(text|core)\("([^"]+)""#)
        for case let url as URL in files where url.pathExtension == "swift" {
            let source = try String(contentsOf: url)
            let ns = source as NSString
            for match in pattern.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
                let table = ns.substring(with: match.range(at: 1))
                let key = ns.substring(with: match.range(at: 2))
                #expect(catalogs[table]?[key] != nil, "\(url.lastPathComponent): \(key)")
            }
        }
    }

    @Test func formattedMessagesPreservePortsAndUserText() {
        for (language, prefix, copy) in [
            (AppLanguage.english, "Remote", "猫 100% Copy"),
            (.simplifiedChinese, "远端", "猫 100% 副本"),
            (.traditionalChinese, "遠端", "猫 100% 副本")
        ] {
            #expect(L10n.localized("forward.remote_summary", table: "Core", language: language,
                                   arguments: ["127.0.0.1", 9000, "127.0.0.1", 3000])
                    == "\(prefix) 127.0.0.1:9000 ← 127.0.0.1:3000")
            #expect(L10n.localized("rule.copy_name", table: "Core", language: language,
                                   arguments: ["猫 100%"]) == copy)
        }
    }

    @Test func languagePreferenceIsBackwardCompatibleAndIsolated() throws {
        let suite = "SSHCat-localization-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.customBinaryPath = "/custom/ssh"
        settings.notificationsEnabled = false
        #expect(settings.language == .system)
        settings.language = .traditionalChinese
        #expect(AppSettings(defaults: defaults).language == .traditionalChinese)
        #expect(defaults.string(forKey: AppSettings.Key.language) == "zh-Hant")
        settings.language = .system
        #expect(defaults.object(forKey: AppSettings.Key.language) == nil)
        defaults.set("unsupported-language", forKey: AppSettings.Key.language)
        #expect(settings.language == .system)
        #expect(settings.customBinaryPath == "/custom/ssh")
        #expect(!settings.notificationsEnabled)
    }

    private func catalog(_ language: AppLanguage, table: String) throws -> [String: String] {
        let url = try #require(L10n.resourceBundle.url(forResource: table, withExtension: "strings",
                                                       subdirectory: nil, localization: language.rawValue))
        return try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
    }

    /// Positional specifiers may reorder arguments; they must preserve the same argument types.
    private func placeholders(_ value: String) throws -> [String] {
        let text = value.replacingOccurrences(of: "%%", with: "") as NSString
        let regex = try NSRegularExpression(pattern: #"%(?:(\d+)\$)?(ld|@)"#)
        return regex.matches(in: text as String, range: NSRange(location: 0, length: text.length)).enumerated().map { index, match in
            let position = match.range(at: 1).location == NSNotFound ? String(index + 1) : text.substring(with: match.range(at: 1))
            return position + ":" + text.substring(with: match.range(at: 2))
        }.sorted()
    }
}
