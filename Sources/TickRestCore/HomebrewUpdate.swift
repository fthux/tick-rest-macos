import Foundation

/// Stable numeric versions only. Pre-releases must not enter the stable update feed.
public struct UpdateVersion: Comparable, Equatable {
    private let components: [Int]

    public init?(_ value: String) {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = Int(part), part.count == 1 || part.first != "0" else { return nil }
            numbers.append(number)
        }
        components = numbers + Array(repeating: 0, count: 3 - numbers.count)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}

public enum HomebrewUpdateError: Error {
    case invalidManifest, unsupportedSchema, invalidCurrentVersion, unavailable, network
}

public struct HomebrewUpdateManifest: Codable, Equatable {
    public let schemaVersion: Int
    public let version: String
    public let minimumSystemVersion: String
    public let releaseNotesURL: URL
    public let releaseHistoryURL: URL?
    public let summary: String

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, version, minimumSystemVersion, releaseNotesURL, releaseHistoryURL, summary
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try fields.decode(Int.self, forKey: .schemaVersion)
        version = try fields.decode(String.self, forKey: .version)
        minimumSystemVersion = try fields.decode(String.self, forKey: .minimumSystemVersion)
        summary = try fields.decode(String.self, forKey: .summary)
        releaseHistoryURL = try fields.decodeIfPresent(URL.self, forKey: .releaseHistoryURL)
        let template = try fields.decodeIfPresent(String.self, forKey: .releaseNotesURL)
            ?? "https://github.com/fthux/tick-rest-macos/releases/tag/v{version}"
        guard let url = URL(string: template.replacingOccurrences(of: "{version}", with: version)) else {
            throw DecodingError.dataCorruptedError(forKey: .releaseNotesURL, in: fields,
                                                   debugDescription: "Invalid release notes URL")
        }
        releaseNotesURL = url
    }

    public static let defaultReleaseHistoryURL = URL(string: "https://fthux.github.io/tick-rest-macos/release-history.html")!

    public var historyURL: URL { releaseHistoryURL ?? Self.defaultReleaseHistoryURL }

    public var historyDetailsURL: URL {
        var url = URLComponents(url: historyURL, resolvingAgainstBaseURL: false)!
        url.fragment = "v" + version.replacingOccurrences(of: ".", with: "-")
        return url.url!
    }

    public func validate() throws {
        guard schemaVersion == 1 else { throw HomebrewUpdateError.unsupportedSchema }
        guard UpdateVersion(version) != nil, UpdateVersion(minimumSystemVersion) != nil,
              summary.count <= 4000,
              let url = URLComponents(url: releaseNotesURL, resolvingAgainstBaseURL: false),
              url.scheme == "https", url.host == "github.com", url.user == nil,
              url.password == nil, url.port == nil,
              url.path.hasPrefix("/fthux/tick-rest-macos/releases/") else {
            throw HomebrewUpdateError.invalidManifest
        }
        if let releaseHistoryURL {
            guard let url = URLComponents(url: releaseHistoryURL, resolvingAgainstBaseURL: false),
                  url.scheme == "https", url.host == "fthux.github.io", url.user == nil,
                  url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
                  url.path == "/tick-rest-macos/release-history.html" else {
                throw HomebrewUpdateError.invalidManifest
            }
        }
    }

    public func isNewer(than currentVersion: String) throws -> Bool {
        try validate()
        guard let current = UpdateVersion(currentVersion), let latest = UpdateVersion(version) else {
            throw HomebrewUpdateError.invalidCurrentVersion
        }
        return latest > current
    }

    public func supports(systemVersion: String) -> Bool {
        guard let system = UpdateVersion(systemVersion), let minimum = UpdateVersion(minimumSystemVersion) else { return false }
        return system >= minimum
    }
}
