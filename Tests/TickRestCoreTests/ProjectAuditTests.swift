import Foundation
import Testing
@testable import TickRestCore

/// Headless defect reproductions. No application, windows, system events or user data.
/// Regression tests for defects found by the project audit.
@Suite(.serialized)
struct ProjectAuditTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func settings(_ id: RestPlanID, mode: BreakStartMode = .automatic) -> Settings {
        var value = Settings(); value.restPlan = .preset(id)
        value.prewarning = 0; value.breakStartMode = mode
        return value
    }
    private func step(_ engine: Engine, _ seconds: Double, _ time: inout Date) {
        time = time.addingTimeInterval(seconds); engine.tick(seconds: seconds, now: time)
    }

    @Test(arguments: [60, 300, 3600])
    func retroactiveIdleDetectionMustNotCountTheSameTimeAsUsageAndAway(_ threshold: Int) {
        var s = settings(.fiftyTen); s.shortInterval = 7200
        s.detectIdle = true; s.idleTimeout = Double(threshold)
        let engine = Engine(settings: s); var time = now
        // Mirror AppController: normal ticks run before the idle threshold; at
        // the threshold probeIdle supplies the LAST INPUT time to beginAway.
        for _ in 1..<threshold { step(engine, 1, &time) }
        time = now.addingTimeInterval(Double(threshold))
        engine.beginAway(at: now, observedAt: time); engine.tick(seconds: 1, now: time)
        time = time.addingTimeInterval(10); engine.endAway(now: time, minimumShort: 600)
        #expect(engine.records.filter { $0.outcome == .natural }.map(\.seconds).reduce(0, +) == 10)
        #expect(engine.shortElapsed == (threshold >= 600 ? 0 : Double(threshold - 1)))
        let summary = TodaySummary(records: engine.records, now: time)
        #expect(summary.usage + summary.rest + summary.natural <= time.timeIntervalSince(now),
                "Usage and time away must not overlap within the same measured wall-clock interval")
    }

    @Test(arguments: [RestPlanID.tickrest, .eye202020, .fiftyTen, .pomodoro], [0.0, 1.0])
    func replacingAPendingPlanDuringPausedRestMustRetainTheCurrentRest(_ plan: RestPlanID, _ elapsed: Double) throws {
        let s = settings(plan); let engine = Engine(settings: s); var time = now
        step(engine, s.shortInterval, &time); step(engine, elapsed, &time)
        let original = try #require(engine.reminder)
        engine.applyPlan(.preset(plan == .fiftyTen ? .pomodoro : .fiftyTen), now: time)
        engine.setPause(.indefinite, now: time)
        let replacement: RestPlanID = plan == .eye202020 ? .pomodoro : .eye202020
        engine.applyPlan(.preset(replacement), now: time)
        #expect(engine.settings.restPlan == s.restPlan && engine.reminder == original
                && engine.pendingPlan == .preset(replacement) && engine.pause == .indefinite,
                "Replacing a pending plan must preserve the paused break and defer the replacement")
        engine.setPause(nil, now: time); step(engine, 1, &time)
        step(engine, original.target - original.elapsed, &time)
        #expect(engine.settings.planID == replacement && engine.pendingPlan == nil)
    }

    @Test(arguments: [RestPlanID.tickrest, .eye202020, .fiftyTen, .pomodoro], BreakStartMode.allCases)
    func changingCardPositionMustPreserveTheNextReminderDeadline(_ plan: RestPlanID, _ mode: BreakStartMode) {
        let s = settings(plan, mode: mode); let engine = Engine(settings: s); var time = now
        step(engine, s.shortInterval - 1, &time)
        var edited = s; edited.gentleReminderPosition = .bottomRight
        engine.updateSettings(edited); step(engine, 1, &time)
        #expect(engine.reminder != nil, "Changing card position must not add 30 seconds of recovery grace")
    }

    @Test func changingCardPositionMustNotRepeatAnAlreadyDeliveredWarning() {
        var s = settings(.eye202020); s.prewarning = 10
        let engine = Engine(settings: s); var time = now
        step(engine, 1190, &time)
        var edited = s; edited.gentleReminderPosition = .center
        engine.updateSettings(edited); step(engine, 20, &time)
        #expect(engine.effects.filter { $0 == .warning(.short) }.count == 1,
                "Moving the card must not deliver the same cycle's warning twice")
    }

    @Test(arguments: [(2026, 3, 8), (2026, 11, 1)], [0, 90, 150, 540, 1439])
    func scheduleTimeBindingMustKeepTheStoredClockTimeOnDSTDays(_ day: (Int, Int, Int), _ storedMinutes: Int) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let today = try #require(calendar.date(from: DateComponents(year: day.0, month: day.1, day: day.2, hour: 12)))
        let displayed = ScheduleClockTime.date(minutes: storedMinutes, on: today, calendar: calendar)
        #expect(calendar.component(.hour, from: displayed) * 60 + calendar.component(.minute, from: displayed) == storedMinutes,
                "The 09:00 schedule renders as 10:00 on spring-forward and 08:00 on fall-back days")
    }

    @Test func deferredCountdownMustIncludeLongerStartupGrace() throws {
        let s = settings(.eye202020, mode: .manual); let engine = Engine(settings: s); var time = now
        step(engine, s.shortInterval, &time); engine.postpone(now: time)
        step(engine, s.singlePostpone - 10, &time)
        let restored = Engine(settings: s, snapshot: engine.snapshot(now: time), now: time)
        let previous = L10n.language; L10n.language = "en"
        defer { L10n.language = previous }
        let display = ReminderDisplay(engine: restored)
        #expect(display.stateText.contains(L10n.clock(restored.graceRemaining)))
        #expect(display.menuStateText.contains(L10n.clock(restored.graceRemaining)))
        #expect(display.countdownText(for: .short).contains(L10n.clock(restored.graceRemaining)),
                "The per-break countdown promises 10 seconds while actual recovery grace is 30 seconds")
    }

    @Test(arguments: [RestPlanID.tickrest, .eye202020, .fiftyTen, .pomodoro])
    func manualRestOutsideScheduleMustDisplayItsRunningState(_ plan: RestPlanID) {
        let previous = L10n.language; L10n.language = "en"
        defer { L10n.language = previous }
        var s = settings(plan); s.scheduleEnabled = true
        var time = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 8))!
        let engine = Engine(settings: s); engine.tick(seconds: 0, now: time)
        engine.startNow(.short, now: time); step(engine, 1, &time)
        #expect(engine.isResting && engine.reminder?.elapsed == 1)
        let display = ReminderDisplay(engine: engine)
        #expect(display.statusSymbolName == "leaf.fill")
        #expect(display.statusDotState == .resting && display.stateText != L10n.text("state.outside"),
                "A running manual break must not be described as paused outside work hours")
        engine.beginAway(at: time)
        #expect(display.statusDotState == .inactive && display.statusSymbolName == "pause.circle.fill")
        #expect(display.stateText == L10n.text("state.away"))
    }

    @Test(arguments: ["en", "zh-Hans", "zh-Hant", "ja", "ko"])
    func roundDurationValidationMustUseTheRoundPlansTerminology(_ language: String) throws {
        var s = settings(.pomodoro); s.shortDuration = 300; s.longDuration = 60
        let key = try #require(s.validationErrorKey)
        let previous = L10n.language; L10n.language = language
        defer { L10n.language = previous }
        #expect(key == "validation.round_duration")
        #expect(L10n.text(key).localizedCaseInsensitiveContains(L10n.text("plan.short_break"))
                && L10n.text(key).localizedCaseInsensitiveContains(L10n.text("plan.long_break")),
                "Pomodoro duration validation must explain long/short breaks instead of unrelated eye/movement labels")
    }

    @Test(arguments: [RestPlanID.tickrest, .eye202020, .fiftyTen, .pomodoro])
    func changingPlanWhileAwayMustNotEraseAlreadyObservedTimeAway(_ plan: RestPlanID) {
        let engine = Engine(settings: settings(plan)); var time = now
        step(engine, 100, &time); engine.beginAway(at: time)
        time = time.addingTimeInterval(30)
        engine.applyPlan(.preset(.fiftyTen), now: time)
        time = time.addingTimeInterval(10)
        engine.endAway(now: time, minimumShort: 600)
        #expect(engine.records.filter { $0.outcome == .natural }.map(\.seconds).reduce(0, +) == 40,
                "A routine switch must keep the 30 seconds away before the switch as well as the 10 after it")
        let natural = engine.records.filter { $0.outcome == .natural }
        #expect(natural.first?.planID == plan && natural.first?.seconds == 30)
        #expect(natural.last?.planID == .fiftyTen && natural.last?.seconds == 10)
    }

    @Test(arguments: [false, true])
    func restartingFocusWhileAwayPreservesEachObservedSegment(_ group: Bool) {
        let engine = Engine(settings: settings(.pomodoro))
        engine.beginAway(at: now, observedAt: now.addingTimeInterval(20))
        engine.restartFocus(group: group, now: now.addingTimeInterval(50))
        engine.endAway(now: now.addingTimeInterval(60), minimumShort: 300)
        #expect(engine.records.filter { $0.outcome == .natural }.map(\.seconds) == [30, 10])
        #expect(engine.records.filter { $0.outcome == .restarted }.count == 1)
    }
    @Test func rollingRetentionMustExcludeExpiredSecondsInsideAMergedUsageRecord() {
        var records: [Record] = []
        for second in stride(from: 5, through: 3600, by: 5) {
            let end = now.addingTimeInterval(Double(second))
            DataStore.append([Record(date: end, kind: nil, outcome: .usage, seconds: 5)], to: &records, now: end)
        }
        let checkTime = now.addingTimeInterval(DataStore.recordRetention + 1800)
        DataStore.append([], to: &records, now: checkTime)
        #expect(records.map(\.seconds).reduce(0, +) == 1800,
                "Only the last 30 minutes of this one-hour record lie within the rolling 90-day retention window")
    }

    @Test func retentionTrimsRestAndNaturalDurationsWithoutChangingEventCounts() {
        let cutoff = now.addingTimeInterval(-DataStore.recordRetention)
        let completed = Record(date: cutoff, kind: .short, outcome: .completed, seconds: 300)
        var records = [
            Record(date: cutoff.addingTimeInterval(10), kind: .short, outcome: .usage, seconds: 20, reminderID: UUID()),
            Record(date: cutoff.addingTimeInterval(30), kind: nil, outcome: .natural, seconds: 60),
            completed
        ]
        DataStore.append([], to: &records, now: now)
        #expect(records.map(\.seconds) == [10, 30, 300])
        #expect(records.last?.id == completed.id)
        let summary = StatisticsSummary(records: records, range: StatisticsDateRange(start: cutoff, end: now))
        #expect(summary.rest == 10 && summary.natural == 30 && summary.completed == 1)
    }

    @Test func usageMergingDoesNotHideGapsOrReorderRecords() {
        var records = [Record(date: now, kind: nil, outcome: .usage, seconds: 5)]
        let later = Record(date: now.addingTimeInterval(8), kind: nil, outcome: .usage, seconds: 5)
        let earlier = Record(date: now.addingTimeInterval(6), kind: nil, outcome: .usage, seconds: 5)
        DataStore.append([later, earlier], to: &records, now: now.addingTimeInterval(10))
        #expect(records.count == 3 && records.map(\.seconds) == [5, 5, 5])
        #expect(records.map(\.date) == [now, later.date, earlier.date])
    }
    @Test(arguments: [RestPlanID.tickrest, .eye202020, .fiftyTen, .pomodoro], BreakStartMode.allCases)
    func postponementBudgetAndIdentitySurviveEachDiskRoundtrip(_ plan: RestPlanID, _ mode: BreakStartMode) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tickrest-project-audit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DataStore(url: directory.appendingPathComponent("state.json"))
        let s = settings(plan, mode: mode); var engine = Engine(settings: s); var time = now
        step(engine, s.shortInterval, &time)
        let id = try #require(engine.reminder?.id)
        for budget in 1...s.postponeLimit {
            engine.postpone(now: time)
            var saved = SavedData(); saved.settings = s; saved.snapshot = engine.snapshot(now: time)
            try store.save(saved); let loaded = store.load()
            #expect(store.loadErrorKey == nil)
            engine = Engine(settings: loaded.settings, snapshot: loaded.snapshot, now: time)
            step(engine, s.postponement(.short), &time); step(engine, 1, &time)
            #expect(engine.reminder?.id == id && engine.reminder?.postponements == budget)
        }
        engine.postpone(now: time)
        #expect(engine.reminder?.postponements == s.postponeLimit)
    }
}
