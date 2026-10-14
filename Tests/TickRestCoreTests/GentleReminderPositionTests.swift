import Foundation
import Testing
@testable import TickRestCore

extension EngineTests {
    @Test(arguments: GentleReminderPosition.allCases)
    func gentleReminderPositionSurvivesSavingAndReloading(_ position: GentleReminderPosition) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tickrest-position-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DataStore(url: directory.appendingPathComponent("state.json"))
        var saved = SavedData()
        saved.settings.gentleReminderPosition = position
        saved.settings.style = .overlay
        try store.save(saved)
        #expect(store.load().settings == saved.settings)
        #expect(store.loadErrorKey == nil)
    }

    @Test(arguments: [false, true])
    func missingOrUnknownPositionDefaultsToTopRightWithoutLosingData(_ unknown: Bool) throws {
        #expect(Settings().gentleReminderPosition == .topRight)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tickrest-legacy-position-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DataStore(url: directory.appendingPathComponent("state.json"))
        var saved = SavedData()
        saved.settings.gentleReminderSize = .mini
        saved.settings.breakStartMode = .manual
        saved.snapshot.shortElapsed = 120
        saved.records = [Record(date: Date(), kind: .short, outcome: .completed)]
        try store.save(saved)
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as? [String: Any])
        var settings = try #require(json["settings"] as? [String: Any])
        if unknown { settings["gentleReminderPosition"] = "unknown" }
        else { settings.removeValue(forKey: "gentleReminderPosition") }
        json["settings"] = settings
        try JSONSerialization.data(withJSONObject: json).write(to: store.url)
        let loaded = store.load()
        #expect(store.loadErrorKey == nil)
        #expect(loaded.settings == saved.settings)
        #expect(loaded.snapshot.shortElapsed == 120)
        #expect(loaded.records.first?.id == saved.records.first?.id)
    }
}
