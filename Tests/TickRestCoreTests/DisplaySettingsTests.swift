import Foundation
import Testing
@testable import TickRestCore

struct DisplaySettingsTests {
    @Test(arguments: DisplayScope.allCases)
    func displaySelectionSurvivesStoreReload(_ scope: DisplayScope) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DataStore(url: directory.appendingPathComponent("state.json"))
        var saved = SavedData()
        saved.settings.displayScope = scope
        saved.settings.selectedDisplayID = "external-display-uuid"
        try store.save(saved)
        let loaded = store.load()
        #expect(store.loadErrorKey == nil)
        #expect(loaded.settings == saved.settings)
    }

    @Test(arguments: [DisplayScope.all, .current])
    func oldDisplaySettingsRemainReadable(_ scope: DisplayScope) throws {
        var settings = Settings()
        settings.displayScope = scope
        settings.shortInterval = 1800
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        json.removeValue(forKey: "selectedDisplayID")
        let loaded = try JSONDecoder().decode(Settings.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(loaded == settings)
        #expect(loaded.selectedDisplayID == nil)
    }

    @Test func changingDisplaySelectionDoesNotRestartARunningRest() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var settings = Settings()
        let engine = Engine(settings: settings, now: now)
        engine.startNow(.short, now: now)
        engine.tick(seconds: 3, now: now.addingTimeInterval(3))
        let reminder = try #require(engine.reminder)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let records = try encoder.encode(engine.records)
        settings.displayScope = .selected
        settings.selectedDisplayID = "external-display-uuid"
        engine.updateSettings(settings)
        #expect(engine.reminder == reminder)
        #expect(try encoder.encode(engine.records) == records)
    }
}
