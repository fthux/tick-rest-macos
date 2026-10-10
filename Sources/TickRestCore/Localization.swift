import Foundation

/// All UI text is resolved here. Add an xx.lproj resource to extend supported languages.
public enum L10n {
    public static var language = "system"
    public static var resourceBundle: Bundle { AppResources.bundle }
    public static var availableLanguages: [String] {
        resourceBundle.localizations.filter { $0 != "Base" }.sorted()
    }
    public static var resolvedLanguage: String {
        resolveLanguage(language, preferredLanguages: Locale.preferredLanguages, availableLanguages: availableLanguages)
    }
    /// Match preferences explicitly: Bundle's default can select an unrelated localization.
    static func resolveLanguage(_ selection: String, preferredLanguages: [String], availableLanguages: [String]) -> String {
        let fallback = availableLanguages.first { $0.caseInsensitiveCompare("en") == .orderedSame } ?? "en"
        let preferences = selection == "system" ? preferredLanguages : [selection]
        for preference in preferences {
            let identifier = preference.replacingOccurrences(of: "_", with: "-")
            if let exact = availableLanguages.first(where: { $0.caseInsensitiveCompare(identifier) == .orderedSame }) { return exact }
            let components = Locale.Language.Components(identifier: identifier)
            guard let code = components.languageCode?.identifier else { continue }
            let candidate: String
            if code == "zh" {
                // Explicit scripts take priority over region; bare Chinese uses Simplified Chinese.
                let script = components.script?.identifier
                if let script, script != "Hans", script != "Hant" { continue }
                let traditional = script == "Hant" || (script == nil && ["TW", "HK", "MO"].contains(components.region?.identifier ?? ""))
                candidate = traditional ? "zh-Hant" : "zh-Hans"
            } else {
                candidate = code
            }
            if let matched = availableLanguages.first(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) { return matched }
        }
        return fallback
    }
    public static var locale: Locale { Locale(identifier: resolvedLanguage) }
    public static func text(_ key: String, _ args: CVarArg...) -> String {
        let english = resourceBundle.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:)) ?? resourceBundle
        let bundle = resourceBundle.path(forResource: resolvedLanguage, ofType: "lproj").flatMap(Bundle.init(path:)) ?? english
        let fallback = english.localizedString(forKey: key, value: key, table: "Localizable")
        let format = bundle.localizedString(forKey: key, value: fallback, table: "Localizable")
            .replacingOccurrences(of: "{appName}", with: AppIdentity.name)
        return args.isEmpty ? format : String(format: format, locale: locale, arguments: args)
    }
    public static func clock(_ seconds: Double) -> String {
        let value = max(0, Int(ceil(seconds)))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
    public static func duration(_ seconds: Double) -> String {
        let minutes = max(0, Int(seconds / 60))
        if minutes >= 60 { return text("duration.hours_minutes", minutes / 60, minutes % 60) }
        if minutes > 0 { return text("duration.minutes_seconds", minutes, max(0, Int(seconds) % 60)) }
        return text("duration.seconds", max(0, Int(seconds)))
    }
    public static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
