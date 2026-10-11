import Foundation
import Testing
@testable import TickRestCore

extension EngineTests {
    @Test(arguments: GentleReminderSize.allCases)
    func gentleReminderSizeSurvivesSavingAndReloading(_ size: GentleReminderSize) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tickrest-card-size-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DataStore(url: directory.appendingPathComponent("state.json"))
        var saved = SavedData()
        saved.settings.gentleReminderSize = size
        saved.settings.style = .overlay // Switching styles must retain the gentle size preference.
        try store.save(saved)

        let loaded = store.load()
        #expect(store.loadErrorKey == nil)
        #expect(loaded.settings == saved.settings)
    }

    @Test func legacySettingsDefaultToNormalWithoutLosingSavedData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tickrest-legacy-card-size-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DataStore(url: directory.appendingPathComponent("state.json"))
        var saved = SavedData()
        saved.settings.shortInterval = 1800
        saved.settings.breakStartMode = .manual
        saved.snapshot.shortElapsed = 120
        saved.records = [Record(date: Date(), kind: .short, outcome: .completed)]
        try store.save(saved)
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as? [String: Any])
        var settings = try #require(json["settings"] as? [String: Any])
        settings.removeValue(forKey: "gentleReminderSize")
        json["settings"] = settings
        try JSONSerialization.data(withJSONObject: json).write(to: store.url)

        let loaded = store.load()
        #expect(store.loadErrorKey == nil)
        #expect(loaded.settings.gentleReminderSize == .normal)
        #expect(loaded.settings == saved.settings)
        #expect(loaded.snapshot.shortElapsed == 120)
        #expect(loaded.records.first?.id == saved.records.first?.id)
    }
}
