import Foundation
import Testing
@testable import TickRestCore

// Extend the existing serialized suite: L10n.language is process-global.
// All persistence fixtures use temporary directories, never the user's state.json.
private enum FunctionalFixture {
    static let now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 12))!
    static func date(_ day: Int = 12, hour: Int, minute: Int = 0, second: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute, second: second))!
    }
    static func settings(_ style: ReminderStyle = .gentle) -> Settings {
        var value = Settings(); value.style = style; value.prewarning = 0
        value.breakStartMode = style == .gentle ? .manual : .automatic
        return value
    }
    static func temporaryStore(_ body: (DataStore, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tickrest-functional-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(DataStore(url: directory.appendingPathComponent("state.json")), directory)
    }
    static func scheduled() -> Settings {
        var value = settings(); value.scheduleEnabled = true; value.weekdays = [2]
        value.scheduleStart = 9 * 60; value.scheduleEnd = 18 * 60
        return value
    }
}

extension EngineTests {
    @Test func functionalDefaultSettingsAndIdentity() {
        let s = Settings()
        #expect(s.validationError == nil)
        #expect(s.shortInterval == 1200 && s.shortDuration == 20)
        #expect(s.longInterval == 3600 && s.longDuration == 300)
        #expect(s.style == .gentle && s.prewarning == 10)
        #expect(s.breakStartMode == .automatic)
        #expect(s.detectIdle && s.idleTimeout == 300 && s.avoidFullscreen)
        #expect(!s.scheduleEnabled && !s.sound && !s.onboardingComplete)
        #expect(AppIdentity.name == "TickRest")
        #expect(AppIdentity.bundleIdentifier == "app.restly.desktop")
        #expect(AppIdentity.dataDirectory == "Restly")
    }

    @Test func functionalTwoShortBreaksThenOneLongBreak() {
        let e = Engine(settings: FunctionalFixture.settings())
        var now = FunctionalFixture.now
        for expected: BreakKind in [.short, .short, .long] {
            now = now.addingTimeInterval(1200); e.tick(seconds: 1200, now: now)
            #expect(e.reminder?.kind == expected)
            #expect(!e.isResting)
            e.start(now: now)
            let seconds = e.settings.duration(expected)
            now = now.addingTimeInterval(seconds); e.tick(seconds: seconds, now: now)
            #expect(e.reminder == nil)
        }
        let summary = TodaySummary(records: e.records, now: now)
        #expect(summary.usage == 3600 && summary.rest == 340 && summary.completed == 3)
        #expect(e.shortElapsed == 0 && e.longElapsed == 0)
    }

    @Test(arguments: BreakKind.allCases)
    func functionalSkipResetsOnlyRequiredCycles(_ kind: BreakKind) {
        let e = Engine(settings: FunctionalFixture.settings())
        let now = FunctionalFixture.now
        e.tick(seconds: e.settings.interval(kind), now: now)
        e.skip(now: now); e.skip(now: now)
        let summary = TodaySummary(records: e.records, now: now)
        #expect(summary.skipped == 1 && summary.completed == 0 && summary.rest == 0)
        #expect(e.shortElapsed == 0)
        #expect(e.longElapsed == (kind == .long ? 0 : 1200))
        #expect(e.reminder == nil)
    }

    @Test func functionalBothDisabledProduceNoReminder() {
        var s = FunctionalFixture.settings(); s.shortEnabled = false; s.longEnabled = false
        let e = Engine(settings: s); e.tick(seconds: 10000, now: FunctionalFixture.now)
        #expect(e.nextKind == nil && e.reminder == nil && e.effects.isEmpty)
        #expect(ReminderDisplay(engine: e).menuBarText.isEmpty)
    }

    @Test(arguments: BreakKind.allCases)
    func functionalSingleEnabledBreak(_ kind: BreakKind) {
        var s = FunctionalFixture.settings(); s.shortEnabled = kind == .short; s.longEnabled = kind == .long
        let e = Engine(settings: s); e.tick(seconds: s.interval(kind), now: FunctionalFixture.now)
        #expect(e.nextKind == kind && e.reminder?.kind == kind)
    }

    @Test func functionalPrewarningOnceThenReminder() {
        var s = FunctionalFixture.settings(); s.prewarning = 10
        let e = Engine(settings: s); let now = FunctionalFixture.now
        e.tick(seconds: 1189, now: now)
        #expect(e.effects.isEmpty)
        e.tick(seconds: 1, now: now.addingTimeInterval(1))
        #expect(e.effects == [.warning(.short)])
        e.tick(seconds: 5, now: now.addingTimeInterval(6))
        #expect(e.effects == [.warning(.short)])
        e.tick(seconds: 5, now: now.addingTimeInterval(11))
        #expect(e.reminder?.kind == .short)
        #expect(e.effects.count == 2)
    }

    @Test func functionalOverlayStartsAutomaticallyAndCompletesOnlyOnce() {
        let e = Engine(settings: FunctionalFixture.settings(.overlay)); let now = FunctionalFixture.now
        e.tick(seconds: 1200, now: now)
        #expect(e.isResting && e.reminder?.elapsed == 0)
        e.tick(seconds: 20, now: now.addingTimeInterval(20))
        e.tick(seconds: 1, now: now.addingTimeInterval(21))
        #expect(e.effects.filter { $0 == .completed(.short) }.count == 1)
        #expect(TodaySummary(records: e.records, now: now).completed == 1)
    }

    @Test(arguments: BreakKind.allCases)
    func functionalLongAndShortPostponementsPreserveIdentity(_ kind: BreakKind) {
        let e = Engine(settings: FunctionalFixture.settings()); var now = FunctionalFixture.now
        e.tick(seconds: e.settings.interval(kind), now: now)
        let id = e.reminder?.id
        for count in 1...2 {
            e.postpone(now: now); _ = e.drain()
            now = now.addingTimeInterval(kind.postponement - 1)
            e.tick(seconds: kind.postponement - 1, now: now)
            #expect(e.effects.isEmpty)
            now = now.addingTimeInterval(1); e.tick(seconds: 1, now: now)
            #expect(e.reminder?.id == id && e.reminder?.postponements == count)
        }
        e.postpone(now: now)
        if case .waiting = e.phase {} else { Issue.record("A third postponement must be rejected") }
    }

    @Test func functionalPostponedShortUpgradesToLongWithNewBudget() {
        var s = FunctionalFixture.settings(); s.longInterval = 1260
        let e = Engine(settings: s); let now = FunctionalFixture.now
        e.tick(seconds: 1200, now: now); let oldID = e.reminder?.id
        e.postpone(now: now); _ = e.drain()
        e.tick(seconds: 60, now: now.addingTimeInterval(60))
        #expect(e.reminder?.kind == .long && e.reminder?.id != oldID)
        #expect(e.reminder?.postponements == 0)
        #expect(e.effects.count == 2 && e.effects.first == .hide)
    }

    @Test(arguments: [5.0, 5.001])
    func functionalOverlayPostponementFiveSecondBoundary(_ elapsed: Double) {
        let e = Engine(settings: FunctionalFixture.settings(.overlay)); let now = FunctionalFixture.now
        e.startNow(.short, now: now); e.tick(seconds: elapsed, now: now.addingTimeInterval(elapsed))
        e.postpone(now: now.addingTimeInterval(elapsed))
        #expect(e.isResting == (elapsed > 5))
        let summary = TodaySummary(records: e.records, now: now)
        #expect(summary.rest == elapsed && summary.completed == 0)
    }

    @Test func functionalTimedPauseFreezesAndExpiresWithGrace() {
        let e = Engine(settings: FunctionalFixture.settings()); let now = FunctionalFixture.now
        e.tick(seconds: 100, now: now)
        e.setPause(.until(now.addingTimeInterval(900)), now: now)
        e.tick(seconds: 899, now: now.addingTimeInterval(899))
        #expect(e.shortElapsed == 100 && e.pause != nil)
        e.tick(seconds: 1, now: now.addingTimeInterval(900))
        #expect(e.pause == nil && e.shortElapsed == 101 && e.graceRemaining == 29)
        #expect(e.reminder == nil)
    }

    @Test func functionalPauseDuringRestRecordsExactlyMeasuredDuration() {
        let e = Engine(settings: FunctionalFixture.settings()); let now = FunctionalFixture.now
        e.startNow(.long, now: now); e.tick(seconds: 30, now: now.addingTimeInterval(30))
        e.setPause(.indefinite, now: now.addingTimeInterval(30))
        e.tick(seconds: 600, now: now.addingTimeInterval(630))
        #expect(!e.isResting && e.pause == .indefinite)
        #expect(TodaySummary(records: e.records, now: now).rest == 30)
        #expect(e.records.filter { $0.outcome == .interrupted }.count == 1)
    }

    @Test func functionalManualStartOverridesPauseButNotAway() {
        let e = Engine(settings: FunctionalFixture.settings()); let now = FunctionalFixture.now
        e.setPause(.indefinite, now: now); e.startNow(.short, now: now)
        #expect(e.pause == nil && e.isResting)
        e.beginAway(at: now); let id = e.reminder?.id
        e.startNow(.long, now: now)
        #expect(e.reminder?.id == id && e.away)
    }

    @Test func functionalAwayDoesNotAccumulateUsageOrRest() {
        let e = Engine(settings: FunctionalFixture.settings()); let now = FunctionalFixture.now
        e.tick(seconds: 100, now: now); e.beginAway(at: now)
        e.tick(seconds: 10, now: now.addingTimeInterval(10))
        #expect(e.shortElapsed == 100 && e.longElapsed == 100)
        e.endAway(now: now.addingTimeInterval(10), minimumShort: 20)
        e.endAway(now: now.addingTimeInterval(10), minimumShort: 20)
        #expect(e.records.filter { $0.outcome == .natural }.count == 1)
        #expect(e.graceRemaining == 30)
    }

    @Test func functionalShortAwayFreezesDeferredBudget() {
        let e = Engine(settings: FunctionalFixture.settings()); let now = FunctionalFixture.now
        e.tick(seconds: 1200, now: now); e.postpone(now: now)
        let id = e.reminder?.id
        e.beginAway(at: now); e.tick(seconds: 10, now: now.addingTimeInterval(10))
        e.endAway(now: now.addingTimeInterval(10), minimumShort: 20)
        if case .deferred(let r, let seconds) = e.phase {
            #expect(r.id == id && r.postponements == 1 && seconds == 120)
        } else { Issue.record("Insufficient natural rest must preserve postponed reminders") }
    }

    @Test func functionalSuppressionHidesWaitingCardAndRestoresAfterGrace() {
        let e = Engine(settings: FunctionalFixture.settings()); let now = FunctionalFixture.now
        e.tick(seconds: 1200, now: now); let id = e.reminder?.id; _ = e.drain()
        e.setSuppressed(true)
        #expect(e.effects == [.hide])
        e.tick(seconds: 10, now: now.addingTimeInterval(10))
        #expect(!e.isResting && e.reminder?.id == id)
        e.setSuppressed(false); _ = e.drain()
        e.tick(seconds: 29, now: now.addingTimeInterval(39))
        #expect(e.effects.isEmpty)
        e.tick(seconds: 1, now: now.addingTimeInterval(40)); e.tick(seconds: 1, now: now.addingTimeInterval(41))
        #expect(e.reminder?.id == id)
        #expect(e.effects.filter { if case .show = $0 { return true }; return false }.count == 1)
    }

    @Test func functionalNaturalRestCancelsSuppressedDueReminder() {
        let e = Engine(settings: FunctionalFixture.settings()); let now = FunctionalFixture.now
        e.setSuppressed(true); e.tick(seconds: 3600, now: now)
        e.beginAway(at: now); e.endAway(now: now.addingTimeInterval(300), minimumShort: 60)
        e.setSuppressed(false); e.tick(seconds: 31, now: now.addingTimeInterval(331))
        #expect(e.reminder == nil && e.shortElapsed == 31 && e.longElapsed == 31)
    }

    @Test func functionalDayScheduleBoundaries() {
        let s = FunctionalFixture.scheduled()
        #expect(!s.isWorkingTime(FunctionalFixture.date(hour: 8, minute: 59)))
        #expect(s.isWorkingTime(FunctionalFixture.date(hour: 9)))
        #expect(s.isWorkingTime(FunctionalFixture.date(hour: 17, minute: 59)))
        #expect(!s.isWorkingTime(FunctionalFixture.date(hour: 18)))
        #expect(!s.isWorkingTime(FunctionalFixture.date(13, hour: 12)))
    }

    @Test func functionalOvernightWeekWrapAndEndBoundary() {
        var s = FunctionalFixture.settings(); s.scheduleEnabled = true; s.weekdays = [7]
        s.scheduleStart = 22 * 60; s.scheduleEnd = 2 * 60
        #expect(s.isWorkingTime(FunctionalFixture.date(17, hour: 22)))
        #expect(s.isWorkingTime(FunctionalFixture.date(18, hour: 1, minute: 59)))
        #expect(!s.isWorkingTime(FunctionalFixture.date(18, hour: 2)))
        #expect(!s.isWorkingTime(FunctionalFixture.date(18, hour: 22)))
    }

    @Test func functionalScheduleExitHidesPendingAndStopsUsage() {
        let e = Engine(settings: FunctionalFixture.scheduled())
        e.tick(seconds: 1200, now: FunctionalFixture.date(hour: 17, minute: 59)); _ = e.drain()
        e.tick(seconds: 1, now: FunctionalFixture.date(hour: 18))
        #expect(e.outsideSchedule && e.reminder == nil && e.shortElapsed == 1200)
        #expect(e.effects == [.hide] && e.records.isEmpty)
    }

    @Test func functionalNextWorkSessionResetsCyclesAndKeepsManualPause() {
        var s = FunctionalFixture.scheduled(); s.weekdays = [2, 3]
        let e = Engine(settings: s)
        e.tick(seconds: 100, now: FunctionalFixture.date(hour: 17))
        e.setPause(.indefinite, now: FunctionalFixture.date(hour: 17))
        e.tick(seconds: 1, now: FunctionalFixture.date(hour: 18))
        e.tick(seconds: 1, now: FunctionalFixture.date(13, hour: 9))
        #expect(e.pause == .indefinite && e.shortElapsed == 0 && e.longElapsed == 0)
        #expect(e.graceRemaining == 30)
    }

    @Test func functionalIntervalShorteningRetainsUsageAndAddsGrace() {
        let e = Engine(settings: FunctionalFixture.settings()); let now = FunctionalFixture.now
        e.tick(seconds: 1000, now: now)
        var s = e.settings; s.shortInterval = 600; e.updateSettings(s)
        #expect(e.shortElapsed == 1000 && e.remaining(.short) == 0 && e.reminder == nil)
        e.tick(seconds: 29, now: now.addingTimeInterval(29)); #expect(e.reminder == nil)
        e.tick(seconds: 1, now: now.addingTimeInterval(30)); #expect(e.reminder == nil)
        e.tick(seconds: 1, now: now.addingTimeInterval(31)); #expect(e.reminder?.kind == .short)
    }

    @Test func functionalActiveRestKeepsOriginalTargetAfterDurationChange() {
        let e = Engine(settings: FunctionalFixture.settings()); let now = FunctionalFixture.now
        e.startNow(.short, now: now); e.tick(seconds: 5, now: now.addingTimeInterval(5))
        var s = e.settings; s.shortDuration = 60; e.updateSettings(s)
        #expect(e.reminder?.target == 20)
        e.tick(seconds: 15, now: now.addingTimeInterval(20))
        #expect(TodaySummary(records: e.records, now: now).completed == 1)
        e.startNow(.short, now: now.addingTimeInterval(20))
        #expect(e.reminder?.target == 60)
    }

    @Test(arguments: BreakKind.allCases)
    func functionalDisablePendingAndReenableFromZero(_ kind: BreakKind) {
        let e = Engine(settings: FunctionalFixture.settings()); let now = FunctionalFixture.now
        e.tick(seconds: e.settings.interval(kind), now: now)
        var s = e.settings
        if kind == .short { s.shortEnabled = false } else { s.longEnabled = false }
        e.updateSettings(s)
        #expect(e.reminder == nil && e.effects.contains(.hide))
        if kind == .short { s.shortEnabled = true } else { s.longEnabled = true }
        e.updateSettings(s)
        #expect(e.remaining(kind) == s.interval(kind) && e.reminder == nil)
    }

    @Test func functionalSnapshotDeferredRoundtripFreezesOfflineTime() throws {
        try FunctionalFixture.temporaryStore { store, _ in
            let now = FunctionalFixture.now; let e = Engine(settings: FunctionalFixture.settings())
            e.tick(seconds: 1200, now: now); e.postpone(now: now)
            e.tick(seconds: 20, now: now.addingTimeInterval(20))
            var saved = SavedData(); saved.settings = e.settings; saved.snapshot = e.snapshot(now: now)
            saved.records = e.drain().1; try store.save(saved)
            let disk = store.load(); let restored = Engine(settings: disk.settings, snapshot: disk.snapshot, now: now.addingTimeInterval(600))
            if case .deferred(let reminder, let remaining) = restored.phase {
                #expect(remaining == 100 && reminder.postponements == 1 && reminder.id == e.reminder?.id)
            } else { Issue.record("Deferred reminders must survive restart") }
            #expect(restored.shortElapsed == e.shortElapsed && restored.longElapsed == e.longElapsed)
        }
    }

    @Test(arguments: [true, false])
    func functionalRestartPauseModes(_ expired: Bool) {
        let now = FunctionalFixture.now; var snapshot = Snapshot()
        snapshot.shortElapsed = 123; snapshot.savedAt = now
        snapshot.pause = expired ? .until(now.addingTimeInterval(-1)) : .indefinite
        let e = Engine(settings: FunctionalFixture.settings(), snapshot: snapshot, now: now)
        #expect(e.pause == (expired ? nil : .indefinite))
        #expect(e.shortElapsed == 123 && e.graceRemaining == 30)
    }

    @Test func functionalRestartInDifferentWorkSessionClearsUsageAndDeferred() {
        var s = FunctionalFixture.scheduled(); s.weekdays = [2, 3]
        var snapshot = Snapshot(); snapshot.savedAt = FunctionalFixture.date(hour: 12)
        snapshot.shortElapsed = 1200; snapshot.longElapsed = 1500
        snapshot.shortCooldown = 100; snapshot.pause = .indefinite
        snapshot.deferredReminder = Reminder(kind: .short, target: 20); snapshot.deferredRemaining = 100
        let e = Engine(settings: s, snapshot: snapshot, now: FunctionalFixture.date(13, hour: 12))
        #expect(e.shortElapsed == 0 && e.longElapsed == 0 && e.reminder == nil)
        #expect(e.remaining(.short) == 1200 && e.pause == .indefinite)
    }

    @Test func functionalOvernightRestartUsesSameSession() {
        var s = FunctionalFixture.scheduled(); s.scheduleStart = 22 * 60; s.scheduleEnd = 2 * 60
        var snapshot = Snapshot(); snapshot.savedAt = FunctionalFixture.date(hour: 23); snapshot.shortElapsed = 500
        let e = Engine(settings: s, snapshot: snapshot, now: FunctionalFixture.date(13, hour: 1))
        #expect(e.shortElapsed == 500)
    }

    @Test func functionalPersistedCrashRestDoesNotDoubleCountSummary() throws {
        try FunctionalFixture.temporaryStore { store, _ in
            let now = FunctionalFixture.now; let e = Engine(settings: FunctionalFixture.settings())
            e.startNow(.long, now: now); e.tick(seconds: 30, now: now.addingTimeInterval(30))
            var saved = SavedData(); saved.settings = e.settings; saved.snapshot = e.snapshot(now: now); saved.records = e.drain().1
            try store.save(saved); var loaded = store.load()
            let restored = Engine(settings: loaded.settings, snapshot: loaded.snapshot, now: now.addingTimeInterval(600))
            DataStore.append(restored.drain().1, to: &loaded.records, now: now.addingTimeInterval(600))
            let summary = TodaySummary(records: loaded.records, now: now)
            #expect(summary.rest == 30 && summary.completed == 0)
            #expect(loaded.records.filter { $0.outcome == .interrupted }.count == 1)
            #expect(!restored.isResting)
        }
    }

    @Test func functionalMissingFileAndNestedAtomicRoundtrip() throws {
        try FunctionalFixture.temporaryStore { store, _ in
            let missing = store.load(); #expect(missing.records.isEmpty && store.loadError == nil)
            var saved = SavedData(); saved.settings.onboardingComplete = true
            saved.settings.language = "en"; saved.settings.theme = .dark
            saved.settings.displayScope = .current; saved.settings.sound = true
            saved.records = [Record(date: FunctionalFixture.now, kind: .short, outcome: .completed)]
            saved.snapshot.shortElapsed = 321
            try store.save(saved); let first = store.load()
            #expect(first.settings == saved.settings && first.records.first?.id == saved.records.first?.id)
            #expect(first.snapshot.shortElapsed == 321)
            saved.records = []; try store.save(saved)
            #expect(store.load().records.isEmpty && store.load().settings == saved.settings)
        }
    }

    @Test(arguments: ["broken-json", "unknown-version", "invalid-settings"])
    func functionalDamagedFilePreservesExactBytes(_ scenario: String) throws {
        try FunctionalFixture.temporaryStore { store, directory in
            var saved = SavedData()
            if scenario == "unknown-version" { saved.version = 99 }
            if scenario == "invalid-settings" { saved.settings.shortInterval = 0 }
            let bytes = scenario == "broken-json" ? Data("{invalid".utf8) : try JSONEncoder().encode(saved)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try bytes.write(to: store.url)
            #expect(store.load().settings == Settings() && store.loadError != nil)
            let backup = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("state-damaged-") })
            #expect(try Data(contentsOf: backup) == bytes)
            try store.save(SavedData())
            #expect(try Data(contentsOf: backup) == bytes)
        }
    }

    @Test func functionalUsageMergingRespectsReminderAndDayBoundaries() {
        let now = FunctionalFixture.now; let id = UUID(); var records: [Record] = []
        let additions = [
            Record(date: now, kind: nil, outcome: .usage, seconds: 1),
            Record(date: now.addingTimeInterval(1), kind: nil, outcome: .usage, seconds: 1),
            Record(date: now.addingTimeInterval(2), kind: .short, outcome: .usage, seconds: 1, reminderID: id),
            Record(date: now.addingTimeInterval(3), kind: .short, outcome: .usage, seconds: 1, reminderID: id),
            Record(date: now.addingTimeInterval(4), kind: .short, outcome: .usage, seconds: 1, reminderID: UUID()),
            Record(date: now.addingTimeInterval(20), kind: nil, outcome: .usage, seconds: 1)
        ]
        DataStore.append(additions, to: &records, now: now)
        #expect(records.count == 4 && records[0].seconds == 2 && records[1].seconds == 2)
        #expect(TodaySummary(records: records, now: now).usage == 3)
        #expect(TodaySummary(records: records, now: now).rest == 3)
    }

    @Test func functionalNinetyDayRetentionExactBoundary() {
        let now = FunctionalFixture.now
        var records = [
            Record(date: now.addingTimeInterval(-90 * 86400 - 1), kind: nil, outcome: .usage, seconds: 1),
            Record(date: now.addingTimeInterval(-90 * 86400), kind: nil, outcome: .usage, seconds: 2),
            Record(date: now, kind: nil, outcome: .usage, seconds: 3)
        ]
        DataStore.append([], to: &records, now: now)
        #expect(records.count == 2 && records.first?.seconds == 2)
    }

    @Test func functionalSummaryFiltersDayAndOutcome() {
        let now = FunctionalFixture.now
        let records = [
            Record(date: now, kind: nil, outcome: .usage, seconds: 100),
            Record(date: now, kind: .short, outcome: .usage, seconds: 10, reminderID: UUID()),
            Record(date: now, kind: nil, outcome: .natural, seconds: 60),
            Record(date: now, kind: .short, outcome: .completed),
            Record(date: now, kind: .short, outcome: .skipped),
            Record(date: now, kind: .short, outcome: .ended),
            Record(date: now, kind: .short, outcome: .postponed),
            Record(date: now, kind: .short, outcome: .interrupted, seconds: 10),
            Record(date: now.addingTimeInterval(-86400), kind: .short, outcome: .completed)
        ]
        let summary = TodaySummary(records: records, now: now)
        #expect(summary.usage == 100 && summary.rest == 10 && summary.natural == 60)
        #expect(summary.completed == 1 && summary.skipped == 1 && summary.ended == 1)
    }

    @Test func functionalDrainConsumesEffectsAndRecordsExactlyOnce() {
        let e = Engine(settings: FunctionalFixture.settings()); e.tick(seconds: 1200, now: FunctionalFixture.now)
        let first = e.drain(); #expect(!first.0.isEmpty && !first.1.isEmpty)
        let second = e.drain(); #expect(second.0.isEmpty && second.1.isEmpty)
        #expect(e.reminder?.kind == .short)
    }

    @Test(arguments: ["short-low", "short-high", "short-duration", "long-low", "long-high", "long-duration", "interval-order", "duration-order", "schedule-days", "schedule-equal"])
    func functionalInvalidSettingsRejected(_ scenario: String) {
        var s = Settings()
        switch scenario {
        case "short-low": s.shortInterval = 59
        case "short-high": s.shortInterval = 7201
        case "short-duration": s.shortDuration = 9
        case "long-low": s.longInterval = 59
        case "long-high": s.longInterval = 14401
        case "long-duration": s.longDuration = 1801
        case "interval-order": s.longInterval = 60
        case "duration-order": s.shortDuration = 300; s.longDuration = 60
        case "schedule-days": s.scheduleEnabled = true; s.weekdays = []
        default: s.scheduleEnabled = true; s.scheduleEnd = s.scheduleStart
        }
        #expect(s.validationError != nil)
    }

    @Test(arguments: ["en", "ja", "ko", "zh-Hans", "zh-Hant"])
    func functionalLocaleResourcesHaveCompleteKeysAndTokens(_ language: String) throws {
        // SwiftPM normalizes localization directory names to lowercase.
        let identifier = try #require(L10n.availableLanguages.first { $0.caseInsensitiveCompare(language) == .orderedSame })
        let bundlePath = try #require(L10n.resourceBundle.path(forResource: identifier, ofType: "lproj"))
        let data = try Data(contentsOf: URL(fileURLWithPath: bundlePath).appendingPathComponent("Localizable.strings"))
        let values = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
        #expect(values.count == 206)
        #expect(values.values.allSatisfy { !$0.isEmpty })
        #expect(values["welcome.title"]?.contains("{appName}") == true)
        #expect(values["menu.remaining"]?.components(separatedBy: "%@").count == 3)
        #expect(values["break.short"] != nil && values["break.long"] != nil)
        #expect(values["reminder.sound_type"] != nil)
        #expect(values["reminder.start_mode"] != nil && values["reminder.start_mode_help"] != nil)
        #expect(values["reminder.size"] != nil && values["reminder.size_help"] != nil)
        #expect(values["rest.idea"] != nil)
        #expect(values["settings.overview"] != nil && values["menu.overview"] != nil)
        #expect(values["overview.start_date"] != nil && values["overview.end_date"] != nil)
        #expect(values["overview.empty"] != nil && values["overview.retention"] != nil && values["overview.partial_day"] != nil)
        for preset in StatisticsPreset.allCases {
            #expect(values["overview.period.\(preset.rawValue)"] != nil)
        }
        for size in GentleReminderSize.allCases {
            #expect(values["reminder.size.\(size.rawValue)"] != nil)
        }
        for mode in BreakStartMode.allCases {
            #expect(values["start_mode.\(mode.rawValue)"] != nil)
        }
        for sound in ReminderSound.allCases {
            #expect(values["sound.\(sound.rawValue.lowercased())"] != nil)
        }
    }

    @Test(arguments: ["zh_CN", "zh-SG", "zh-Hans-TW", "zh-TW", "zh-HK", "zh-Hant-CN", "en-US", "ja-JP", "ko-KR", "fr-FR"])
    func functionalLanguageResolution(_ preference: String) {
        let available = ["en", "ja", "ko", "zh-hans", "zh-hant"]
        let expected: String
        switch preference {
        case "zh_CN", "zh-SG", "zh-Hans-TW": expected = "zh-hans"
        case "zh-TW", "zh-HK", "zh-Hant-CN": expected = "zh-hant"
        case "ja-JP": expected = "ja"
        case "ko-KR": expected = "ko"
        default: expected = "en"
        }
        #expect(L10n.resolveLanguage("system", preferredLanguages: [preference], availableLanguages: available) == expected)
        #expect(L10n.resolveLanguage(preference, preferredLanguages: [], availableLanguages: available) == expected)
    }

    @Test func functionalLanguagePreferenceOrderAndExplicitOverride() {
        let available = ["en", "ja", "ko", "zh-Hans", "zh-Hant"]
        #expect(L10n.resolveLanguage("system", preferredLanguages: ["fr-FR", "ja-JP", "zh-CN"], availableLanguages: available) == "ja")
        #expect(L10n.resolveLanguage("ko", preferredLanguages: ["zh-CN"], availableLanguages: available) == "ko")
        #expect(L10n.resolveLanguage("system", preferredLanguages: [], availableLanguages: available) == "en")
    }

    @Test(arguments: [-1.0, 0, 0.1, 59, 59.1, 60, 3600])
    func functionalClockFormatting(_ seconds: Double) {
        let expected = ["00:00", "00:00", "00:01", "00:59", "01:00", "01:00", "60:00"]
        let inputs = [-1.0, 0, 0.1, 59, 59.1, 60, 3600]
        #expect(L10n.clock(seconds) == expected[inputs.firstIndex(of: seconds)!])
    }

    @Test func functionalDisabledScheduleAllowsEveryDay() {
        var s = Settings(); s.scheduleEnabled = false; s.weekdays = []
        #expect(s.isWorkingTime(FunctionalFixture.date(18, hour: 3)))
        #expect(s.validationError == nil)
    }
}
