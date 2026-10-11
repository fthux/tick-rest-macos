import XCTest
import TickRestCore
@testable import TickRestApp

@MainActor
final class AppBuildInfoTests: XCTestCase {
    private func info(architecture: String, configuration: String = "release") -> AppBuildInfo {
        AppBuildInfo(infoDictionary: [
            "CFBundleShortVersionString": "2.4.1",
            "CFBundleVersion": "108",
            "AppBuildArchitecture": architecture,
            "AppBuildConfiguration": configuration
        ])
    }

    func testInstalledPackageArchitectureDoesNotDependOnRunningCPU() {
        let previous = L10n.language
        L10n.language = "en"
        defer { L10n.language = previous }
        let variants = [
            "arm64": "Apple Silicon (arm64)",
            "x86_64": "Intel (x86_64)",
            "universal": "Universal"
        ]
        for (architecture, title) in variants {
            let build = info(architecture: architecture)
            XCTAssertEqual(build.versionDescription, "Version 2.4.1 (Build 108) · \(title) · Release")
        }
        XCTAssertEqual(info(architecture: "universal", configuration: "debug").versionDescription,
                       "Version 2.4.1 (Build 108) · Universal · Debug")
    }

    func testExistingBuildDescriptionRefreshesInEveryLanguage() {
        let previous = L10n.language
        defer { L10n.language = previous }
        let build = info(architecture: "universal")
        let expected = [
            "en": "Version 2.4.1 (Build 108) · Universal · Release",
            "zh-Hans": "版本 2.4.1（构建 108）· Universal · Release",
            "zh-Hant": "版本 2.4.1（組建 108）· Universal · Release",
            "ja": "バージョン 2.4.1（ビルド 108）· Universal · Release",
            "ko": "버전 2.4.1 (빌드 108) · Universal · Release"
        ]
        for (language, description) in expected {
            L10n.language = language
            XCTAssertEqual(build.versionDescription, description, language)
        }
    }

    func testMissingOrInvalidMetadataDoesNotInventPackageDetails() {
        for dictionary: [String: Any] in [[:], [
            "CFBundleShortVersionString": " \n",
            "CFBundleVersion": 108,
            "AppBuildArchitecture": "all",
            "AppBuildConfiguration": "profile"
        ]] {
            let build = AppBuildInfo(infoDictionary: dictionary)
            XCTAssertEqual(build.version, "—")
            XCTAssertEqual(build.buildNumber, "—")
            XCTAssertEqual(build.architecture, .unknown)
            XCTAssertEqual(build.configuration, .unknown)
        }
    }
}
