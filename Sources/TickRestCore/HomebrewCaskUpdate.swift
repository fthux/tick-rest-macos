import Foundation

/// Reads static metadata without evaluating Ruby or executing anything from the remote tap.
public enum HomebrewCaskUpdate {
    public static func parse(_ data: Data, channel: AppDistributionChannel) throws -> HomebrewUpdateManifest {
        guard data.count <= 64 * 1024, let source = String(data: data, encoding: .utf8) else {
            throw HomebrewUpdateError.invalidManifest
        }
        let tokens = captures(#"(?m)^[ \t]*cask[ \t]+["']([^"']+)["'][ \t]+do[ \t]*(?:#.*)?$"#, in: source)
        let versions = captures(#"(?m)^[ \t]*version[ \t]+["']([^"']+)["'][ \t]*(?:#.*)?$"#, in: source)
        let declarations = captures(#"(?m)^[ \t]*(version|cask)\b"#, in: source)
        guard tokens == [channel.caskToken], versions.count == 1, declarations.count == 2,
              let release = UpdateRelease(caskVersion: versions[0]) else { throw HomebrewUpdateError.invalidManifest }

        let systems = captures(#"(?m)^[ \t]*depends_on[ \t]+macos:[ \t]*(.+?)[ \t]*(?:#.*)?$"#, in: source)
        var minimum = "13.0"
        if !systems.isEmpty {
            guard systems.count == 1 else { throw HomebrewUpdateError.invalidManifest }
            let names = ["big_sur": "11.0", "monterey": "12.0", "ventura": "13.0", "sonoma": "14.0",
                         "sequoia": "15.0", "tahoe": "26.0"]
            let requirement = systems[0].trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            let symbols = captures(#"^(?:>=\s*)?:([a-z_]+)$"#, in: requirement)
            if let symbol = symbols.first, let version = names[symbol] { minimum = version }
            else { throw HomebrewUpdateError.invalidManifest }
        }
        // Literal release tags also handle builds whose tag differs from the marketing version.
        let prefix = "https://github.com/fthux/\(channel.repository)/releases/download/"
        let tags = captures(NSRegularExpression.escapedPattern(for: prefix) + #"([^/\s"']+)/"#, in: source)
        let literalTags = Set(tags.filter { !$0.contains("#{") })
        guard literalTags.count <= 1 else { throw HomebrewUpdateError.invalidManifest }
        let tag = literalTags.first ?? "v" + release.version
        guard !tag.contains("?"), !tag.contains("#"), !tag.contains("%"), !tag.contains("\\") else {
            throw HomebrewUpdateError.invalidManifest
        }
        guard let notes = URL(string: "https://github.com/fthux/\(channel.repository)/releases/tag/" + tag) else {
            throw HomebrewUpdateError.invalidManifest
        }
        let update = HomebrewUpdateManifest(release: release, channel: channel, minimumSystemVersion: minimum,
                                           releaseNotesURL: notes)
        try update.validate()
        return update
    }

    private static func captures(_ pattern: String, in source: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap {
            Range($0.range(at: 1), in: source).map { String(source[$0]) }
        }
    }
}
