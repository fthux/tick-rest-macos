import Foundation
import Testing
@testable import TickRestCore

extension EngineTests {
    @Test func testExistingLoadErrorUsesNewLanguageWithoutReloadingData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory); L10n.language = "zh-Hans" }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("state.json")
        try Data("broken".utf8).write(to: url)
        let store = DataStore(url: url)
        L10n.language = "zh-Hans"
        _ = store.load()
        #expect(store.loadErrorKey == "error.load")
        let chinese = try #require(store.loadError)
        L10n.language = "en"
        #expect(store.loadError == L10n.text("error.load"))
        #expect(store.loadError != chinese)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func testValidationKeepsKeyAndResolvesMessageInCurrentLanguage() {
        defer { L10n.language = "zh-Hans" }
        var settings = Settings(); settings.idleTimeout = 0
        let key = settings.validationErrorKey
        #expect(key == "validation.idle_timeout")
        L10n.language = "zh-Hans"
        let chinese = settings.validationError
        L10n.language = "ja"
        #expect(settings.validationErrorKey == key)
        #expect(settings.validationError == L10n.text("validation.idle_timeout"))
        #expect(settings.validationError != chinese)
    }
}
