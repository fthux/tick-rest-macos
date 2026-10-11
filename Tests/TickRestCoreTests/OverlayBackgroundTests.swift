import Foundation
import Testing
@testable import TickRestCore

struct OverlayBackgroundTests {
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
