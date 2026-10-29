import Foundation
import XCTest
@testable import TickRestCore

final class HomebrewCaskUpdateTests: XCTestCase {
    private func cask(_ version: String = "1.0.1,2", system: String = ":ventura", extra: String = "") -> String {
        """
        cask "tickrest-dev" do
          version "\(version)"
          depends_on macos: \(system)
          variants = {
            "arm64" => ["https://github.com/fthux/tick-rest-macos-dev/releases/download/build-2/arm.zip", "hash"],
            "universal" => ["https://github.com/fthux/tick-rest-macos-dev/releases/download/build-2/all.zip", "hash"],
          }
          url download_url
          \(extra)
        end
        """
    }

    private func parse(_ source: String, channel: AppDistributionChannel = .dev) throws -> HomebrewUpdateManifest {
        try HomebrewCaskUpdate.parse(Data(source.utf8), channel: channel)
    }

    func testVariantCaskExtractsVersionBuildChannelAndActualReleaseTag() throws {
        let update = try parse(cask())
        XCTAssertEqual(update.version, "1.0.1")
        XCTAssertEqual(update.buildNumber, "2")
        XCTAssertEqual(update.channel, .dev)
        XCTAssertEqual(update.minimumSystemVersion, "13.0")
        XCTAssertEqual(update.releaseNotesURL.absoluteString, "https://github.com/fthux/tick-rest-macos-dev/releases/tag/build-2")
        XCTAssertTrue(try update.isNewer(than: "1.0.1", currentBuild: "1"))
        XCTAssertFalse(try update.isNewer(than: "1.0.2", currentBuild: "1"))
    }

    func testStableCaskWithoutBuildAndWithInterpolatedTag() throws {
        let source = """
        cask 'tickrest' do
          version '1.2.0' # release
          url "https://github.com/fthux/tick-rest-macos/releases/download/v\u{23}{version}/TickRest.zip"
        end
        """
        let update = try parse(source, channel: .stable)
        XCTAssertNil(update.buildNumber)
        XCTAssertEqual(update.minimumSystemVersion, "13.0")
        XCTAssertEqual(update.releaseNotesURL.lastPathComponent, "v1.2.0")
    }

    func testMacOSRequirements() throws {
        for (requirement, expected) in [(":ventura", "13.0"), ("\">= :sequoia\"", "15.0"), (":tahoe", "26.0")] {
            XCTAssertEqual(try parse(cask(system: requirement)).minimumSystemVersion, expected)
        }
        for invalid in [":unknown", "[:ventura, :sonoma]", "ENV.fetch('MIN_OS')", "\"<= :ventura\""] {
            XCTAssertThrowsError(try parse(cask(system: invalid)))
        }
    }

    func testRejectsWrongChannelDynamicVersionsAndAmbiguousDeclarations() {
        XCTAssertThrowsError(try parse(cask(), channel: .stable))
        for invalid in ["latest", "1.0.1-beta", "1.0.1,", "01.0.1", "1.0.1,2,3", "\u{23}{ENV['VERSION']}"] {
            XCTAssertThrowsError(try parse(cask(invalid)))
        }
        for extra in ["version \"2.0.0\"", "version ENV.fetch('VERSION')", "depends_on macos: :sonoma", "cask \"other\" do"] {
            XCTAssertThrowsError(try parse(cask(extra: extra)))
        }
    }

    func testRejectsConflictingReleaseTagsAndMalformedPayloads() {
        XCTAssertThrowsError(try parse(cask(extra: "url \"https://github.com/fthux/tick-rest-macos-dev/releases/download/another/a.zip\"")))
        XCTAssertThrowsError(try parse("<html>Unavailable</html>"))
        XCTAssertThrowsError(try HomebrewCaskUpdate.parse(Data(repeating: 32, count: 65537), channel: .dev))
        XCTAssertThrowsError(try HomebrewCaskUpdate.parse(Data([0xff]), channel: .dev))
    }
}
