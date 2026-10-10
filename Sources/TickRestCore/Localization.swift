import Foundation

/// All UI text is resolved here. Add an xx.lproj resource to extend supported languages.
public enum L10n {
    public static var language = "system"
    public static var resourceBundle: Bundle { AppResources.bundle }
    public static var availableLanguages: [String] {
        resourceBundle.localizations.filter { $0 != "Base" }.sorted()
    }
    public static var resolvedLanguage: String {
        if language != "system", let matched = availableLanguages.first(where: { $0.caseInsensitiveCompare(language) == .orderedSame }) { return matched }
        return Bundle.preferredLocalizations(from: availableLanguages).first ?? "zh-Hans"
    }
    public static var locale: Locale { Locale(identifier: resolvedLanguage) }
    public static func text(_ key: String, _ args: CVarArg...) -> String {
        let path = resourceBundle.path(forResource: resolvedLanguage, ofType: "lproj")
            ?? resourceBundle.path(forResource: "zh-Hans", ofType: "lproj")
        let bundle = path.flatMap(Bundle.init(path:)) ?? resourceBundle
        let format = bundle.localizedString(forKey: key, value: nil, table: "Localizable")
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
