import Foundation
import TickRestCore

/// Describes the installed package, including both slices of a Universal build.
struct AppBuildInfo {
    enum Architecture: String {
        case arm64, x86_64, universal, unknown

        var title: String {
            switch self {
            case .arm64: return "Apple Silicon (arm64)"
            case .x86_64: return "Intel (x86_64)"
            case .universal: return "Universal"
            case .unknown: return L10n.text("about.build_unknown")
            }
        }
    }

    enum Configuration: String {
        case debug, release, unknown

        var title: String {
            switch self {
            case .debug: return "Debug"
            case .release: return "Release"
            case .unknown: return L10n.text("about.build_unknown")
            }
        }
    }

    static let current = AppBuildInfo(infoDictionary: Bundle.main.infoDictionary ?? [:])

    let version: String
    let buildNumber: String
    let architecture: Architecture
    let configuration: Configuration

    init(infoDictionary: [String: Any]) {
        func string(_ key: String) -> String? {
            guard let value = infoDictionary[key] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        version = string("CFBundleShortVersionString") ?? "—"
        buildNumber = string("CFBundleVersion") ?? "—"
        // The running CPU cannot distinguish a Universal package from a thin one.
        architecture = string("AppBuildArchitecture").flatMap(Architecture.init(rawValue:)) ?? .unknown
        configuration = string("AppBuildConfiguration").flatMap(Configuration.init(rawValue:)) ?? .unknown
    }

    var versionDescription: String {
        L10n.text("about.version", version, buildNumber, architecture.title, configuration.title)
    }

    var shortVersionDescription: String {
        L10n.text("about.version_short", version, buildNumber)
    }

    var packageDescription: String { "\(architecture.title) · \(configuration.title)" }
}
