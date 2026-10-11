import Foundation
import Testing
@testable import TickRestCore

struct OverlayBackgroundTests {
    @Test func backgroundEditsPreserveDueReminderAndPendingPlan() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let engine = Engine(settings: Settings())
        engine.tick(seconds: engine.settings.shortInterval - engine.settings.prewarning, now: now)
        let effects = engine.effects
        var settings = engine.settings
        settings.overlayBackgroundColor = SRGBColor(red: 0.8, green: 0.7, blue: 0.6)
        engine.updateSettings(settings)
        #expect(engine.effects == effects && engine.graceRemaining == 0)
        engine.tick(seconds: settings.prewarning, now: now)
        #expect(engine.isResting)
        engine.tick(seconds: 3, now: now)
        engine.applyPlan(.preset(.pomodoro), now: now)
        let reminder = try #require(engine.reminder)
        let pending = engine.pendingPlan
        settings = engine.settings; settings.overlayBackgroundColor = Settings.defaultOverlayBackgroundColor
        engine.updateSettings(settings)
        #expect(engine.reminder == reminder && engine.pendingPlan == pending)
        #expect(engine.graceRemaining == 0)
    }

    @Test func customBackgroundSurvivesSaveAndReload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DataStore(url: directory.appendingPathComponent("state.json"))
        var data = SavedData()
        data.settings.overlayBackgroundColor = SRGBColor(red: 0.8, green: 0.7, blue: 0.6)
        data.settings.style = .overlay
        try store.save(data)
        let loaded = store.load()
        #expect(store.loadErrorKey == nil)
        #expect(loaded.settings == data.settings)
    }

    @Test(arguments: ["missing", "invalid", "null"])
    func olderOrInvalidBackgroundKeepsOtherSavedData(_ value: String) throws {
        var saved = SavedData()
        saved.settings.language = "ja"; saved.settings.shortInterval = 900
        saved.snapshot.shortElapsed = 123
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        var settings = try #require(json["settings"] as? [String: Any])
        if value == "missing" { settings.removeValue(forKey: "overlayBackgroundColor") }
        else { settings["overlayBackgroundColor"] = value == "null" ? NSNull() : ["red": "invalid"] as Any }
        json["settings"] = settings
        let loaded = try JSONDecoder().decode(SavedData.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(loaded.settings.overlayBackgroundColor == Settings.defaultOverlayBackgroundColor)
        #expect(loaded.settings.language == "ja" && loaded.settings.shortInterval == 900)
        #expect(loaded.snapshot.shortElapsed == 123)
    }
}
