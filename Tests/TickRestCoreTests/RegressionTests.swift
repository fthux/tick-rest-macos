import Foundation
import Testing
@testable import TickRestCore

// Ordinary failing assertions document unresolved product defects. Do not suppress
// them with withKnownIssue: a repaired implementation should make this suite green.
extension EngineTests {
    @Test func regressionWaitingReminderKeepsIdentityAndPostponementBudgetAfterRestart() throws {
        var s = Settings(); s.prewarning = 0
        s.breakStartMode = .manual
        let now = Date(); let e = Engine(settings: s)
        e.tick(seconds: 1200, now: now)
        let id = try #require(e.reminder?.id)
        e.postpone(now: now); e.tick(seconds: 120, now: now.addingTimeInterval(120))
        e.postpone(now: now); e.tick(seconds: 120, now: now.addingTimeInterval(240))
        #expect(e.reminder?.postponements == 2)
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(e.snapshot(now: now.addingTimeInterval(240))))
        let restored = Engine(settings: s, snapshot: snapshot, now: now.addingTimeInterval(300))
        #expect(!restored.isResting && restored.effects.isEmpty)
        restored.tick(seconds: 30, now: now.addingTimeInterval(330))
        #expect(restored.effects.isEmpty)
        restored.tick(seconds: 1, now: now.addingTimeInterval(331))
        #expect(restored.reminder?.id == id)
        #expect(restored.reminder?.postponements == 2)
        restored.postpone(now: now.addingTimeInterval(331))
        if case .waiting = restored.phase {} else { Issue.record("Restart must not grant a third postponement") }
    }

    @Test(arguments: BreakKind.allCases)
    func regressionShortenThenLengthenIntervalPreservesAccumulatedUsage(_ kind: BreakKind) {
        var initial = Settings(); initial.shortEnabled = kind == .short; initial.longEnabled = kind == .long
        initial.shortInterval = 1200; initial.longInterval = 1200
        let now = Date(); let e = Engine(settings: initial)
        e.tick(seconds: 1000, now: now)
        var s = e.settings
        if kind == .short { s.shortInterval = 600 } else { s.longInterval = 600 }
        e.updateSettings(s)
        e.tick(seconds: 1, now: now.addingTimeInterval(1))
        #expect(e.remaining(kind) == 0 && e.reminder == nil)
        if kind == .short { s.shortInterval = 1200 } else { s.longInterval = 1200 }
        e.updateSettings(s)
        #expect((kind == .short ? e.shortElapsed : e.longElapsed) == 1000)
        #expect(e.remaining(kind) == 200)
        e.tick(seconds: 1000, now: now.addingTimeInterval(1001))
        #expect((kind == .short ? e.shortElapsed : e.longElapsed) == 1200)
    }

    @Test func regressionUsageEndingExactlyAtMidnightBelongsToPreviousDay() {
        let midnight = Calendar.current.startOfDay(for: Date()); let e = Engine(settings: Settings())
        e.tick(seconds: 5, now: midnight)
        #expect(TodaySummary(records: e.records, now: midnight.addingTimeInterval(-1)).usage == 5)
        #expect(TodaySummary(records: e.records, now: midnight).usage == 0)
    }

    @Test func regressionRestEndingExactlyAtMidnightUsesPreviousDayDurationAndNewDayCount() {
        let midnight = Calendar.current.startOfDay(for: Date()); let e = Engine(settings: Settings())
        e.startNow(.short, now: midnight.addingTimeInterval(-20))
        e.tick(seconds: 20, now: midnight)
        #expect(TodaySummary(records: e.records, now: midnight.addingTimeInterval(-1)).rest == 20)
        let today = TodaySummary(records: e.records, now: midnight)
        #expect(today.rest == 0 && today.completed == 1)
    }

    @Test func regressionNaturalRestCrossingMidnightSplitsByDay() {
        let midnight = Calendar.current.startOfDay(for: Date()); let e = Engine(settings: Settings())
        e.beginAway(at: midnight.addingTimeInterval(-60))
        e.endAway(now: midnight.addingTimeInterval(60), minimumShort: 20)
        #expect(TodaySummary(records: e.records, now: midnight.addingTimeInterval(-1)).natural == 60)
        #expect(TodaySummary(records: e.records, now: midnight).natural == 60)
        #expect(e.records.filter { $0.outcome == .natural }.reduce(0) { $0 + $1.seconds } == 120)
    }

    @Test func regressionNaturalRestAcrossSeveralDaysSplitsEveryDay() {
        let calendar = Calendar.current; let midnight = calendar.startOfDay(for: Date())
        let followingDay = calendar.date(byAdding: .day, value: 1, to: midnight)!
        let e = Engine(settings: Settings())
        e.beginAway(at: midnight.addingTimeInterval(-60))
        e.endAway(now: followingDay.addingTimeInterval(60), minimumShort: 20)
        #expect(TodaySummary(records: e.records, now: midnight.addingTimeInterval(-1)).natural == 60)
        #expect(TodaySummary(records: e.records, now: midnight).natural == followingDay.timeIntervalSince(midnight))
        #expect(TodaySummary(records: e.records, now: followingDay).natural == 60)
        #expect(e.remaining(.short) == 1200 && e.remaining(.long) == 3600)
        #expect(!e.records.contains { $0.outcome == .completed })
        #expect(e.records.reduce(0) { $0 + $1.seconds } == followingDay.timeIntervalSince(midnight) + 120)
    }

    @Test func regressionNaturalRestEndingAtMidnightBelongsToPreviousDay() {
        let midnight = Calendar.current.startOfDay(for: Date()); let e = Engine(settings: Settings())
        e.beginAway(at: midnight.addingTimeInterval(-60))
        e.endAway(now: midnight, minimumShort: 20)
        #expect(TodaySummary(records: e.records, now: midnight.addingTimeInterval(-1)).natural == 60)
        #expect(TodaySummary(records: e.records, now: midnight).natural == 0)
        #expect(e.records.count == 1 && e.records.first?.seconds == 60)
    }

    @Test(arguments: [true, false])
    func regressionSleepAcrossScheduleEndEmitsOneInterruptionPerReminder(_ away: Bool) {
        let calendar = Calendar.current
        let end = calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 18))!
        var s = Settings(); s.scheduleEnabled = true; s.weekdays = [2]; s.prewarning = 0
        let e = Engine(settings: s)
        e.tick(seconds: 1, now: end.addingTimeInterval(-40))
        e.startNow(.long, now: end.addingTimeInterval(-30))
        e.tick(seconds: 20, now: end.addingTimeInterval(-10))
        let id = e.reminder?.id
        if away { e.beginAway(at: end.addingTimeInterval(-10)) }
        // The controller timer continues running during a locked user session.
        e.tick(seconds: 1, now: end)
        if away { e.endAway(now: end.addingTimeInterval(10), minimumShort: 20) }
        #expect(e.records.filter { $0.outcome == .interrupted && $0.reminderID == id }.count == 1)
        #expect(e.records.filter { $0.outcome == .interrupted }.allSatisfy { $0.seconds == 0 })
        #expect(TodaySummary(records: e.records, now: end).rest == 20)
        #expect(!e.isResting && e.reminder == nil)
    }

    @Test(arguments: [-1.0, 60, 61, Double.infinity, Double.nan])
    func regressionInvalidPrewarningRejected(_ seconds: Double) {
        var s = Settings(); s.shortInterval = 60; s.prewarning = seconds
        #expect(s.validationErrorKey == "validation.prewarning")
    }

    @Test(arguments: BreakKind.allCases)
    func regressionPrewarningUsesOnlyEnabledIntervals(_ kind: BreakKind) {
        var s = Settings(); s.shortInterval = 60; s.longInterval = 120
        s.shortEnabled = kind == .short; s.longEnabled = kind == .long
        s.prewarning = s.interval(kind) - 1
        #expect(s.validationError == nil)
        s.prewarning = s.interval(kind)
        #expect(s.validationErrorKey == "validation.prewarning")
        s.prewarning = 0
        #expect(s.validationError == nil)
        s.shortEnabled = false; s.longEnabled = false; s.prewarning = 300
        #expect(s.validationError == nil)
    }

    @Test(arguments: ["start-negative", "start-overflow", "end-negative", "end-overflow", "weekday-zero", "weekday-eight", "weekday-mixed"])
    func regressionInvalidScheduleValuesRejected(_ scenario: String) {
        var s = Settings(); s.scheduleEnabled = true
        switch scenario {
        case "start-negative": s.scheduleStart = -1
        case "start-overflow": s.scheduleStart = 1440
        case "end-negative": s.scheduleEnd = -1
        case "end-overflow": s.scheduleEnd = 1440
        case "weekday-zero": s.weekdays = [0]
        case "weekday-mixed": s.weekdays = [2, 8]
        default: s.weekdays = [8]
        }
        #expect(s.validationErrorKey == "validation.schedule")
        s.scheduleEnabled = false
        #expect(s.validationErrorKey == "validation.schedule")
    }

    @Test func regressionValidScheduleBoundsAndDisabledEmptyDays() {
        var s = Settings(); s.scheduleEnabled = true; s.weekdays = Set(1...7)
        s.scheduleStart = 0; s.scheduleEnd = 1439
        #expect(s.validationError == nil)
        s.scheduleStart = 1439; s.scheduleEnd = 0
        #expect(s.validationError == nil)
        s.scheduleEnabled = false; s.weekdays = []; s.scheduleStart = 0; s.scheduleEnd = 0
        #expect(s.validationError == nil)
        s.scheduleEnabled = true
        #expect(s.validationErrorKey == "validation.schedule")
    }

    @Test(arguments: ["minutes", "weekdays"])
    func regressionInvalidScheduleFileIsPreserved(_ scenario: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tickrest-invalid-schedule-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DataStore(url: directory.appendingPathComponent("state.json"))
        var saved = SavedData(); saved.settings.scheduleEnabled = true
        if scenario == "minutes" { saved.settings.scheduleStart = -1 }
        else { saved.settings.weekdays = [8] }
        try store.save(saved)
        let original = try Data(contentsOf: store.url)
        let loaded = store.load()
        #expect(loaded.settings == Settings() && store.loadErrorKey == "error.load")
        let backup = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("state-damaged-") })
        #expect(try Data(contentsOf: backup) == original)
    }
}
