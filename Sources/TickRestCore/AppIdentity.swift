import Foundation

/// Shared identity loaded from the same configuration used by the package and app builder.
public enum AppIdentity {
    private struct Configuration: Decodable {
        let name: String
        let bundleIdentifier: String
        let dataDirectory: String
    }

    private static let configuration: Configuration = {
        guard let url = AppResources.bundle.url(forResource: "AppIdentity", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(Configuration.self, from: data) else {
            preconditionFailure("Missing or invalid AppIdentity.json")
        }
        return value
    }()

    public static var name: String { configuration.name }
    // Keep these stable across branding changes to retain saved data and system registration.
    public static var bundleIdentifier: String { configuration.bundleIdentifier }
    public static var dataDirectory: String { configuration.dataDirectory }
    public static func identifier(_ suffix: String) -> String { "\(bundleIdentifier).\(suffix)" }
}

enum AppResources {
    static let bundle: Bundle = {
        if let name = Bundle.main.object(forInfoDictionaryKey: "AppResourceBundle") as? String,
           let url = Bundle.main.url(forResource: name, withExtension: "bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return .module
    }()
}
