import Foundation
import Testing
@testable import TickRestCore

extension EngineTests {
    @Test func defaultGentleReminderStartsAfterPrewarningWithoutConfirmation() {
        let now = Date(); let e = Engine(settings: Settings())
        e.tick(seconds: 1190, now: now)
        #expect(e.effects == [.warning(.short)] && !e.isResting)
        e.tick(seconds: 10, now: now.addingTimeInterval(10))
        #expect(e.isResting && e.reminder?.elapsed == 0)
        #expect(ReminderDisplay(engine: e).menuBarText == "00:20")
        e.tick(seconds: 1, now: now.addingTimeInterval(11))
        #expect(e.reminder?.elapsed == 1)
        e.tick(seconds: 19, now: now.addingTimeInterval(30))
        e.tick(seconds: 1, now: now.addingTimeInterval(31))
        let summary = TodaySummary(records: e.records, now: now)
        #expect(summary.rest == 20 && summary.completed == 1)
        #expect(e.effects.filter { $0 == .completed(.short) }.count == 1)
    }

    @Test(arguments: ReminderStyle.allCases, BreakStartMode.allCases)
    func breakStartModeIsIndependentOfReminderStyle(_ style: ReminderStyle, _ mode: BreakStartMode) {
        for kind in BreakKind.allCases {
            var s = Settings(); s.style = style; s.breakStartMode = mode; s.prewarning = 0
            let now = Date(); let e = Engine(settings: s)
            e.tick(seconds: s.interval(kind), now: now)
            #expect(e.reminder?.kind == kind && e.reminder?.elapsed == 0)
            #expect(e.isResting == (mode == .automatic))
            let id = e.reminder?.id
            if mode == .manual {
                e.tick(seconds: 30, now: now.addingTimeInterval(30))
                #expect(e.reminder?.elapsed == 0 && e.reminder?.id == id)
                let waiting = TodaySummary(records: e.records, now: now)
                #expect(waiting.rest == 0 && waiting.completed == 0)
                #expect(ReminderDisplay(engine: e).menuStateText == L10n.text("menu.waiting"))
                e.start(now: now.addingTimeInterval(30))
                #expect(e.isResting && e.reminder?.id == id)
            }
            e.tick(seconds: s.duration(kind), now: now.addingTimeInterval(30 + s.duration(kind)))
            #expect(e.reminder == nil)
            let summary = TodaySummary(records: e.records, now: now)
            #expect(summary.rest == s.duration(kind) && summary.completed == 1)
        }
    }

    @Test(arguments: ReminderStyle.allCases, BreakKind.allCases)
    func automaticRestCanBePostponedTwiceAndRestartsWithSameIdentity(_ style: ReminderStyle, _ kind: BreakKind) throws {
        var s = Settings(); s.style = style; s.prewarning = 0
        // This assertion sums a single day's records; late-night runs must not cross midnight.
        var now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3600)
        let e = Engine(settings: s, now: now)
        e.tick(seconds: s.interval(kind), now: now)
        let id = try #require(e.reminder?.id)
        for count in 1...2 {
            now = now.addingTimeInterval(10); e.tick(seconds: 10, now: now)
            e.postpone(now: now)
            #expect(!e.isResting && e.reminder?.postponements == count)
            now = now.addingTimeInterval(kind.postponement)
            e.tick(seconds: kind.postponement, now: now)
            #expect(e.isResting && e.reminder?.id == id && e.reminder?.elapsed == 0)
        }
        e.postpone(now: now)
        #expect(e.isResting && e.reminder?.postponements == 2)
        e.tick(seconds: s.duration(kind), now: now.addingTimeInterval(s.duration(kind)))
        let summary = TodaySummary(records: e.records, now: now)
        #expect(summary.rest == 20 + s.duration(kind) && summary.completed == 1)
        #expect(e.records.filter { $0.outcome == .postponed }.count == 2)
    }

    @Test(arguments: ReminderStyle.allCases, [5.0, 5.001, 19.0])
    func automaticRestCanBePostponedThroughoutItsDuration(_ style: ReminderStyle, _ seconds: Double) {
        var s = Settings(); s.style = style
        let now = Date(); let e = Engine(settings: s)
        e.tick(seconds: 1200, now: now)
        e.tick(seconds: seconds, now: now.addingTimeInterval(seconds))
        e.postpone(now: now.addingTimeInterval(seconds))
        #expect(!e.isResting && e.reminder?.postponements == 1 && e.reminder?.elapsed == 0)
        #expect(e.records.filter { $0.outcome == .postponed }.count == 1)
        #expect(TodaySummary(records: e.records, now: now).rest == seconds)
    }

    @Test(arguments: ReminderStyle.allCases, BreakKind.allCases)
    func explicitSkipOfRunningTimerResetsCyclesAndDoesNotCountCompletion(_ style: ReminderStyle, _ kind: BreakKind) {
        var s = Settings(); s.style = style
        let now = Date(); let e = Engine(settings: s)
        e.tick(seconds: s.interval(kind), now: now)
        e.tick(seconds: 3, now: now.addingTimeInterval(3))
        e.skip(now: now.addingTimeInterval(3)); e.skip(now: now.addingTimeInterval(3))
        let summary = TodaySummary(records: e.records, now: now)
        #expect(summary.skipped == 1 && summary.ended == 0 && summary.completed == 0 && summary.rest == 3)
        #expect(e.reminder == nil && e.remaining(kind) == s.interval(kind))
        #expect(e.shortElapsed == 0 && e.longElapsed == (kind == .long ? 0 : 1200))
    }

    @Test func automaticGentleEarlyEndKeepsRetryAndMeasuredTime() {
        let now = Date(); let e = Engine(settings: Settings())
        e.tick(seconds: 1200, now: now)
        e.tick(seconds: 3, now: now.addingTimeInterval(3)); e.finish(now: now.addingTimeInterval(3))
        #expect(e.reminder == nil && e.remaining(.short) == 120)
        let summary = TodaySummary(records: e.records, now: now)
        #expect(summary.rest == 3 && summary.ended == 1 && summary.skipped == 0 && summary.completed == 0)
        e.tick(seconds: 120, now: now.addingTimeInterval(123))
        #expect(e.isResting && e.reminder?.elapsed == 0)
    }

    @Test(arguments: BreakStartMode.allCases)
    func changingStartModeKeepsCurrentReminderAndAppliesOnNextPresentation(_ mode: BreakStartMode) throws {
        var s = Settings(); s.breakStartMode = mode
        let now = Date(); let e = Engine(settings: s)
        e.tick(seconds: 1200, now: now)
        let id = try #require(e.reminder?.id)
        s.breakStartMode = mode == .automatic ? .manual : .automatic
        e.updateSettings(s)
        #expect(e.reminder?.id == id && e.isResting == (mode == .automatic))
        e.skip(now: now)
        e.tick(seconds: 1200, now: now.addingTimeInterval(1200))
        e.tick(seconds: 1, now: now.addingTimeInterval(1201))
        #expect(e.reminder?.id != id && e.isResting == (s.breakStartMode == .automatic))
    }

    @Test func automaticStartsStillRespectPauseSuppressionAndAway() {
        let now = Date(); let e = Engine(settings: Settings())
        e.setPause(.indefinite, now: now); e.tick(seconds: 1200, now: now)
        #expect(e.reminder == nil && e.shortElapsed == 0)
        e.setPause(nil, now: now); e.setSuppressed(true)
        e.tick(seconds: 1200, now: now)
        #expect(e.reminder == nil && e.remaining(.short) == 0)
        e.beginAway(at: now); e.setSuppressed(false)
        e.tick(seconds: 30, now: now.addingTimeInterval(30))
        #expect(e.reminder == nil && e.away)
        e.endAway(now: now.addingTimeInterval(1), minimumShort: 20)
        e.tick(seconds: 30, now: now.addingTimeInterval(31))
        #expect(e.reminder == nil)
        e.tick(seconds: 1, now: now.addingTimeInterval(32))
        #expect(e.isResting && e.reminder?.kind == .short)
    }

    @Test(arguments: BreakStartMode.allCases)
    func startModeSurvivesSavingAndReloading(_ mode: BreakStartMode) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tickrest-start-mode-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DataStore(url: directory.appendingPathComponent("state.json"))
        var saved = SavedData(); saved.settings.breakStartMode = mode
        saved.settings.shortInterval = 1800; saved.snapshot.shortElapsed = 120
        try store.save(saved)
        let loaded = store.load()
        #expect(store.loadErrorKey == nil && loaded.settings == saved.settings)
        #expect(loaded.snapshot.shortElapsed == 120)
    }

    @Test func legacySettingsAdoptAutomaticStartsWithoutLosingData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tickrest-legacy-start-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DataStore(url: directory.appendingPathComponent("state.json"))
        var saved = SavedData(); saved.settings.shortInterval = 1800; saved.settings.sound = true
        saved.snapshot.shortElapsed = 120; saved.snapshot.pause = .indefinite
        saved.records = [Record(date: Date(), kind: .short, outcome: .completed)]
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        var settings = try #require(json["settings"] as? [String: Any])
        settings.removeValue(forKey: "breakStartMode"); json["settings"] = settings
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: json).write(to: store.url)
        let loaded = store.load()
        #expect(store.loadErrorKey == nil && loaded.settings == saved.settings)
        #expect(loaded.settings.breakStartMode == .automatic && loaded.snapshot.pause == .indefinite)
        #expect(loaded.snapshot.shortElapsed == 120 && loaded.records.first?.id == saved.records.first?.id)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["state.json"])
    }
}
