import Foundation
import Testing
@testable import TickRestCore

extension EngineTests {
    @Test(arguments: [RestPlanID.tickrest, .eye202020, .fiftyTen, .pomodoro], BreakStartMode.allCases)
    func statusDotFollowsWarningWaitingRestAndCompletion(_ plan: RestPlanID, _ mode: BreakStartMode) {
        var settings = Settings(); settings.restPlan = .preset(plan); settings.breakStartMode = mode
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let engine = Engine(settings: settings); let display = ReminderDisplay(engine: engine)
        #expect(display.statusDotState == .working)
        let remaining = engine.remaining(engine.nextKind!)
        engine.tick(seconds: remaining - settings.prewarning, now: now)
        #expect(display.statusDotState == .attention)
        #expect(display.stateText == L10n.text("state.break_soon", settings.breakTitle(engine.nextKind!), L10n.clock(settings.prewarning)))
        engine.tick(seconds: settings.prewarning, now: now)
        #expect(display.statusDotState == (mode == .manual ? .attention : .resting))
        if mode == .manual { engine.start(now: now) }
        #expect(display.statusDotState == .resting)
        engine.tick(seconds: engine.reminder!.target, now: now)
        #expect(display.statusDotState == .working)
    }

    @Test func statusDotDistinguishesPostponementAndEarlyEndCooldown() {
        var settings = Settings(); settings.breakStartMode = .manual; settings.prewarning = 0
        let now = Date(); let engine = Engine(settings: settings)
        let display = ReminderDisplay(engine: engine)
        engine.tick(seconds: settings.shortInterval, now: now)
        engine.postpone(now: now)
        #expect(display.statusDotState == .deferred)
        engine.tick(seconds: settings.shortPostpone, now: now)
        #expect(display.statusDotState == .attention)
        engine.start(now: now); engine.tick(seconds: 1, now: now); engine.finish(now: now)
        #expect(engine.remaining(.short) > 0)
        #expect(display.statusDotState == .working)
    }

    @Test func statusDotHonorsPauseAwayScheduleAndDisabledReminders() {
        let now = Date(); let engine = Engine(settings: Settings())
        let display = ReminderDisplay(engine: engine)
        engine.startNow(.short, now: now); engine.beginAway(at: now)
        #expect(engine.isResting && display.statusDotState == .inactive)
        engine.endAway(now: now.addingTimeInterval(600), minimumShort: 20)
        engine.setPause(.indefinite, now: now)
        #expect(display.statusDotState == .inactive)
        engine.setPause(nil, now: now)
        #expect(display.statusDotState == .working)

        var settings = Settings(); settings.scheduleEnabled = true; settings.weekdays = []
        let outside = Engine(settings: settings); outside.tick(seconds: 1, now: now)
        #expect(ReminderDisplay(engine: outside).statusDotState == .inactive)
        settings = Settings(); settings.shortEnabled = false; settings.longEnabled = false
        let disabled = ReminderDisplay(engine: Engine(settings: settings))
        #expect(disabled.statusDotState == .inactive)
        #expect(disabled.stateText == L10n.text("state.reminders_off"))
    }

    @Test func statusDotHonorsFullscreenButKeepsActiveRestBlue() {
        let now = Date(); let engine = Engine(settings: Settings())
        let display = ReminderDisplay(engine: engine)
        engine.setSuppressed(true)
        #expect(display.statusDotState == .deferred)
        engine.startNow(.short, now: now)
        #expect(display.statusDotState == .resting)
        #expect(display.menuStateText == L10n.text("state.resting", engine.reminder!.title, L10n.clock(engine.reminder!.target)))
        engine.setPause(.indefinite, now: now)
        #expect(display.statusDotState == .inactive)
    }

    @Test func statusDotOnlyUsesPurpleGraceWhenAReminderIsDue() {
        let now = Date(); var snapshot = Snapshot(); snapshot.savedAt = now
        let normal = Engine(settings: Settings(), snapshot: snapshot, now: now)
        #expect(normal.graceRemaining > 0 && ReminderDisplay(engine: normal).statusDotState == .working)
        snapshot.shortElapsed = Settings().shortInterval
        let due = Engine(settings: Settings(), snapshot: snapshot, now: now)
        let display = ReminderDisplay(engine: due)
        #expect(display.statusDotState == .deferred)
        due.tick(seconds: 30, now: now)
        #expect(display.statusDotState == .attention)
        due.tick(seconds: 1, now: now)
        #expect(display.statusDotState == .resting)
    }

    @Test func changingStatusDotCannotResetGraceOrRepeatWarnings() {
        let now = Date(); let engine = Engine(settings: Settings())
        engine.tick(seconds: 1190, now: now)
        let phase = engine.phase; let snapshot = engine.snapshot(now: now)
        let effects = engine.effects; let records = engine.records
        var settings = engine.settings; settings.showStatusDot = false
        settings.statusDotPalette.attention = StatusDotColor(red: 0.3, green: 0.2, blue: 0.7)
        engine.updateSettings(settings)
        #expect(engine.phase == phase && engine.graceRemaining == 0)
        #expect(engine.shortElapsed == snapshot.shortElapsed && engine.longElapsed == snapshot.longElapsed)
        #expect(engine.effects == effects && engine.records.count == records.count)
        engine.tick(seconds: 10, now: now)
        #expect(engine.isResting)
        #expect(engine.effects.filter { $0 == .warning(.short) }.count == 1)

        var saved = Snapshot(); saved.savedAt = now; saved.shortElapsed = 1200
        let recovering = Engine(settings: Settings(), snapshot: saved, now: now)
        recovering.tick(seconds: 15, now: now)
        settings = recovering.settings; settings.showStatusDot = false
        recovering.updateSettings(settings)
        #expect(recovering.graceRemaining == 15)
    }

    @Test func changingStatusDotPreservesActiveAndPendingRestPlan() throws {
        let now = Date(); let engine = Engine(settings: Settings())
        engine.startNow(.long, now: now); engine.tick(seconds: 3, now: now)
        engine.applyPlan(.preset(.pomodoro), now: now)
        let phase = engine.phase; let pending = engine.pendingPlan; let effects = engine.effects
        var settings = engine.settings; settings.statusDotPalette.resting = StatusDotColor(red: 1, green: 0, blue: 0)
        engine.updateSettings(settings)
        #expect(engine.phase == phase && engine.pendingPlan == pending && engine.effects == effects)
        #expect(try #require(engine.reminder).elapsed == 3)
    }

    @Test func statusDotSettingsSurviveSaveAndReloadIndependentlyOfCountdown() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DataStore(url: directory.appendingPathComponent("state.json"))
        var data = SavedData(); data.settings.showCountdown = false; data.settings.showStatusDot = false
        for (index, state) in StatusDotState.allCases.enumerated() {
            data.settings.statusDotPalette[state] = StatusDotColor(red: Double(index) / 5, green: 0.3, blue: 0.8)
        }
        try store.save(data)
        let loaded = store.load()
        #expect(store.loadErrorKey == nil && loaded.settings == data.settings)
        var restored = loaded.settings; restored.statusDotPalette = StatusDotPalette()
        #expect(!restored.showStatusDot && !restored.showCountdown)
    }

    @Test func legacyStatusDotSettingsUseDefaultsWithoutLosingSavedData() throws {
        var saved = SavedData(); saved.settings.showCountdown = false; saved.settings.shortInterval = 900
        saved.snapshot.shortElapsed = 123
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        var settings = try #require(json["settings"] as? [String: Any])
        settings.removeValue(forKey: "showStatusDot"); settings.removeValue(forKey: "statusDotPalette")
        json["settings"] = settings
        let loaded = try JSONDecoder().decode(SavedData.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(loaded.settings.showStatusDot && loaded.settings.statusDotPalette == StatusDotPalette())
        #expect(!loaded.settings.showCountdown && loaded.settings.shortInterval == 900 && loaded.snapshot.shortElapsed == 123)
    }

    @Test func invalidPaletteFallsBackWithoutDiscardingOtherSettings() throws {
        var settings = Settings(); settings.showStatusDot = false; settings.language = "ja"
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        json["statusDotPalette"] = ["working": "invalid"]
        let loaded = try JSONDecoder().decode(Settings.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(loaded.statusDotPalette == StatusDotPalette() && !loaded.showStatusDot && loaded.language == "ja")
    }
}
