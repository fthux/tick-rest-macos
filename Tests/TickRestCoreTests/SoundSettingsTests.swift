import Foundation
import Testing
@testable import TickRestCore

extension EngineTests {
    @Test(arguments: ReminderSound.allCases)
    func reminderSoundSurvivesSavingAndReloading(_ sound: ReminderSound) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tickrest-sounds-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DataStore(url: directory.appendingPathComponent("state.json"))
        var saved = SavedData()
        saved.settings.sound = true
        saved.settings.reminderSound = sound
        try store.save(saved)

        let loaded = store.load()
        #expect(store.loadErrorKey == nil)
        #expect(loaded.settings == saved.settings)
    }

    @Test func legacySoundSettingsKeepToneAndSavedState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tickrest-legacy-sound-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DataStore(url: directory.appendingPathComponent("state.json"))
        var saved = SavedData()
        saved.settings.sound = true
        saved.settings.shortInterval = 1800
        saved.snapshot.shortElapsed = 120
        saved.records = [Record(date: Date(), kind: .short, outcome: .completed)]
        try store.save(saved)
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as? [String: Any])
        var settings = try #require(json["settings"] as? [String: Any])
        settings.removeValue(forKey: "reminderSound")
        json["settings"] = settings
        try JSONSerialization.data(withJSONObject: json).write(to: store.url)

        let loaded = store.load()
        #expect(store.loadErrorKey == nil)
        #expect(loaded.settings == saved.settings)
        #expect(loaded.settings.reminderSound == .glass)
        #expect(loaded.snapshot.shortElapsed == 120)
        #expect(loaded.records.first?.id == saved.records.first?.id)
    }
}
