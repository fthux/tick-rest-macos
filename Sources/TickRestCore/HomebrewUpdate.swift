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
    case invalidManifest, unsupportedSchema, invalidCurrentVersion, unavailable, network, rateLimited
}

public struct HomebrewUpdateManifest: Codable, Equatable {
    public let schemaVersion: Int
    public let version: String
    public let buildNumber: String?
    public let channel: AppDistributionChannel?
    public let minimumSystemVersion: String
    public let releaseNotesURL: URL
    public let releaseHistoryURL: URL?
    public let summary: String

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, version, buildNumber, channel, minimumSystemVersion, releaseNotesURL, releaseHistoryURL, summary
    }

    public init(release: UpdateRelease, channel: AppDistributionChannel, minimumSystemVersion: String,
                releaseNotesURL: URL, summary: String = "") {
        schemaVersion = 1; version = release.version; buildNumber = release.build; self.channel = channel
        self.minimumSystemVersion = minimumSystemVersion; self.releaseNotesURL = releaseNotesURL
        releaseHistoryURL = nil; self.summary = summary
    }

    public func withSummary(_ summary: String) -> Self {
        Self(release: release, channel: channel ?? .stable, minimumSystemVersion: minimumSystemVersion,
             releaseNotesURL: releaseNotesURL, summary: String(summary.prefix(4000)))
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try fields.decode(Int.self, forKey: .schemaVersion)
        version = try fields.decode(String.self, forKey: .version)
        buildNumber = try fields.decodeIfPresent(String.self, forKey: .buildNumber)
        channel = try fields.decodeIfPresent(AppDistributionChannel.self, forKey: .channel)
        minimumSystemVersion = try fields.decode(String.self, forKey: .minimumSystemVersion)
        summary = try fields.decode(String.self, forKey: .summary)
        releaseHistoryURL = try fields.decodeIfPresent(URL.self, forKey: .releaseHistoryURL)
        let repository = (channel ?? .stable).repository
        let template = try fields.decodeIfPresent(String.self, forKey: .releaseNotesURL)
            ?? "https://github.com/fthux/\(repository)/releases/tag/v{version}"
        guard let url = URL(string: template.replacingOccurrences(of: "{version}", with: version)) else {
            throw DecodingError.dataCorruptedError(forKey: .releaseNotesURL, in: fields,
                                                   debugDescription: "Invalid release notes URL")
        }
        releaseNotesURL = url
    }

    public static let defaultReleaseHistoryURL = URL(string: "https://fthux.github.io/tick-rest-macos/release-history.html")!

    public var historyURL: URL { releaseHistoryURL ?? (channel ?? .stable).releaseHistoryURL }

    public var historyDetailsURL: URL {
        var url = URLComponents(url: historyURL, resolvingAgainstBaseURL: false)!
        url.fragment = "v" + version.replacingOccurrences(of: ".", with: "-")
        return url.url!
    }

    public func validate() throws {
        guard schemaVersion == 1 else { throw HomebrewUpdateError.unsupportedSchema }
        guard UpdateVersion(version) != nil, UpdateVersion(minimumSystemVersion) != nil,
              buildNumber == nil || UpdateVersion(buildNumber!) != nil,
              summary.count <= 4000,
              let url = URLComponents(url: releaseNotesURL, resolvingAgainstBaseURL: false),
              url.scheme == "https", url.host == "github.com", url.user == nil,
              url.password == nil, url.port == nil,
              url.path.hasPrefix("/fthux/\((channel ?? .stable).repository)/releases/") else {
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

    public var release: UpdateRelease { UpdateRelease(version: version, build: buildNumber) }
    public func isNewer(than currentVersion: String, currentBuild: String? = nil) throws -> Bool {
        try validate()
        guard let current = UpdateVersion(currentVersion), let latest = UpdateVersion(version) else {
            throw HomebrewUpdateError.invalidCurrentVersion
        }
        if latest != current { return latest > current }
        guard let buildNumber, let currentBuild, UpdateVersion(currentBuild) != nil else { return false }
        return UpdateRelease(version: currentVersion, build: currentBuild) < UpdateRelease(version: version, build: buildNumber)
    }

    public func supports(systemVersion: String) -> Bool {
        guard let system = UpdateVersion(systemVersion), let minimum = UpdateVersion(minimumSystemVersion) else { return false }
        return system >= minimum
    }
}
