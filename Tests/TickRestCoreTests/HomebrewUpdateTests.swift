import Foundation
import XCTest
@testable import TickRestCore

final class HomebrewUpdateTests: XCTestCase {
    func testNumericVersionOrderingAndEquivalentComponents() throws {
        XCTAssertGreaterThan(try XCTUnwrap(UpdateVersion("1.10.0")), try XCTUnwrap(UpdateVersion("1.9.9")))
        XCTAssertGreaterThan(try XCTUnwrap(UpdateVersion("2.0.0")), try XCTUnwrap(UpdateVersion("1.99.99")))
        XCTAssertEqual(UpdateVersion("1"), UpdateVersion("1.0.0"))
        XCTAssertEqual(UpdateVersion("13.0"), UpdateVersion("13.0.0"))
    }

    func testStableFeedRejectsPrereleasesAndMalformedVersions() {
        for value in ["", "—", "1.0.0-beta.1", "1.0.0+build", "v1.0.0", "1..0", "1.0.", "-1.0", "1.2.3.4",
                      " 1.0", "1.0\n", "01.0.0", "１.0", "999999999999999999999999999"] {
            XCTAssertNil(UpdateVersion(value), value)
        }
    }

    func testManifestCompatibilityAndDowngradeProtection() throws {
        let update = try decode()
        XCTAssertTrue(try update.isNewer(than: "1.9.0"))
        XCTAssertFalse(try update.isNewer(than: "1.10.0"))
        XCTAssertFalse(try update.isNewer(than: "2.0.0"))
        XCTAssertTrue(update.supports(systemVersion: "13.0.0"))
        XCTAssertFalse(update.supports(systemVersion: "12.7.6"))
        XCTAssertThrowsError(try update.isNewer(than: "—"))
    }

    func testRejectsUnknownSchemasAndUntrustedReleaseLinks() throws {
        for url in ["http://github.com/fthux/tick-rest-macos/releases/tag/v2", "https://evil.example/releases/v2",
                    "https://github.com/other/app/releases/v2", "https://github.com/fthux/tick-rest-macos/issues/1",
                    "https://github.com:8443/fthux/tick-rest-macos/releases/tag/v2"] {
            XCTAssertThrowsError(try decode(url: url).validate(), url)
        }
        XCTAssertThrowsError(try decode(schema: 2).validate())
        XCTAssertThrowsError(try decode(version: "2.0.0-beta").validate())
        XCTAssertThrowsError(try decode(minimum: "macOS 13").validate())
    }

    func testRepositoryManifestIsValid() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("updates/homebrew-update.json"))
        let manifest = try JSONDecoder().decode(HomebrewUpdateManifest.self, from: data)
        try manifest.validate()
        XCTAssertEqual(manifest.releaseNotesURL.absoluteString,
                       "https://github.com/fthux/tick-rest-macos/releases/tag/v\(manifest.version)")
    }

    func testReleaseLinkTemplateTracksVersionAndSurvivesCacheRoundTrip() throws {
        for version in ["1.0.0", "1.10.0", "2.0.0"] {
            let update = try decode(version: version,
                                    url: "https://github.com/fthux/tick-rest-macos/releases/tag/v{version}")
            try update.validate()
            XCTAssertEqual(update.releaseNotesURL.absoluteString,
                           "https://github.com/fthux/tick-rest-macos/releases/tag/v\(version)")
            let cached = try JSONDecoder().decode(HomebrewUpdateManifest.self, from: JSONEncoder().encode(update))
            XCTAssertEqual(cached, update)
        }
        XCTAssertThrowsError(try decode(url: "https://evil.example/releases/tag/v{version}").validate())
    }

    func testMissingReleaseLinkDefaultsToVersionAndLegacyLinkIsPreserved() throws {
        let fields: [String: Any] = ["schemaVersion": 1, "version": "2.3.4",
                                     "minimumSystemVersion": "13.0", "summary": "Changes"]
        let update = try JSONDecoder().decode(HomebrewUpdateManifest.self,
                                              from: JSONSerialization.data(withJSONObject: fields))
        try update.validate()
        XCTAssertEqual(update.releaseNotesURL.absoluteString,
                       "https://github.com/fthux/tick-rest-macos/releases/tag/v2.3.4")
        let legacyURL = "https://github.com/fthux/tick-rest-macos/releases/tag/1.10.0"
        let legacy = try decode(url: legacyURL)
        try legacy.validate()
        XCTAssertEqual(legacy.releaseNotesURL.absoluteString, legacyURL)
    }

    func testOptionalHistoryLinkAndVersionAnchor() throws {
        let oldManifest = try decode()
        XCTAssertNil(oldManifest.releaseHistoryURL)
        XCTAssertEqual(oldManifest.historyDetailsURL.absoluteString,
                       "https://fthux.github.io/tick-rest-macos/release-history.html#v1-10-0")
        let encoded = try JSONEncoder().encode(oldManifest)
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for url in ["https://fthux.github.io/tick-rest-macos/release-history.html",
                    "https://evil.example/release-history.html", "http://fthux.github.io/tick-rest-macos/release-history.html",
                    "https://fthux.github.io/other/release-history.html",
                    "https://fthux.github.io/tick-rest-macos/release-history.html?redirect=other"] {
            fields["releaseHistoryURL"] = url
            let update = try JSONDecoder().decode(HomebrewUpdateManifest.self, from: JSONSerialization.data(withJSONObject: fields))
            if url == HomebrewUpdateManifest.defaultReleaseHistoryURL.absoluteString {
                XCTAssertNoThrow(try update.validate())
                XCTAssertEqual(update.historyURL.absoluteString, url)
            } else {
                XCTAssertThrowsError(try update.validate())
            }
        }
    }

    private func decode(version: String = "1.10.0", minimum: String = "13.0", schema: Int = 1,
                        url: String = "https://github.com/fthux/tick-rest-macos/releases/tag/v1.10.0") throws -> HomebrewUpdateManifest {
        let json: [String: Any] = ["schemaVersion": schema, "version": version, "minimumSystemVersion": minimum,
                                   "releaseNotesURL": url, "summary": "Update notes"]
        return try JSONDecoder().decode(HomebrewUpdateManifest.self, from: JSONSerialization.data(withJSONObject: json))
    }
}
