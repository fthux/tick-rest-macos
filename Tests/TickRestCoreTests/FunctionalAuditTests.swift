import Foundation
import Testing
@testable import TickRestCore

/// Functional scenarios use a virtual clock and isolated stores; no real preferences
/// or statistics are touched. Failing assertions describe unresolved defects.
@Suite(.serialized)
struct FunctionalAuditTests {
    private var now: Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 12))!
    }
    private func settings(_ plan: RestPlanID, mode: BreakStartMode = .automatic,
                          style: ReminderStyle = .gentle) -> Settings {
        var value = Settings()
        value.restPlan = .preset(plan); value.prewarning = 0
        value.breakStartMode = mode; value.style = style
        return value
    }
    private func step(_ engine: Engine, _ seconds: Double, _ time: inout Date) {
        time = time.addingTimeInterval(seconds)
        engine.tick(seconds: seconds, now: time)
    }
    private func store(_ body: (DataStore, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tickrest-audit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(DataStore(url: directory.appendingPathComponent("nested/state.json")), directory)
    }

    @Test(arguments: [RestPlanID.tickrest, .eye202020, .fiftyTen, .pomodoro],
          [(BreakStartMode.automatic, ReminderStyle.gentle), (.automatic, .overlay),
           (.manual, .gentle), (.manual, .overlay)])
    func fullCyclePersistsSettingsProgressAndStatistics(_ plan: RestPlanID,
                                                       _ presentation: (BreakStartMode, ReminderStyle)) throws {
        let (mode, style) = presentation
        try store { disk, _ in
            let s = settings(plan, mode: mode, style: style)
            let engine = Engine(settings: s); var time = now
            step(engine, s.shortInterval, &time)
            let id = try #require(engine.reminder?.id)
            if mode == .manual { engine.start(now: time) }
            step(engine, s.shortDuration, &time)
            let drained = engine.drain()
            var saved = SavedData(); saved.settings = engine.settings
            saved.snapshot = engine.snapshot(now: time)
            DataStore.append(drained.1, to: &saved.records, now: time)
            try disk.save(saved)
            let loaded = disk.load()
            #expect(disk.loadErrorKey == nil && loaded.settings == s)
            let summary = TodaySummary(records: loaded.records, now: time)
            #expect(summary.usage == s.shortInterval)
            #expect(summary.rest == s.shortDuration && summary.completed == 1)
            #expect(summary.focusCompleted == (plan == .pomodoro ? 1 : 0))
            #expect(loaded.records.filter { $0.outcome == .completed && $0.reminderID == id }.count == 1)
            let restored = Engine(settings: loaded.settings, snapshot: loaded.snapshot, now: time)
            #expect(restored.remaining(.short) == s.shortInterval)
            #expect(restored.reminder == nil && restored.completedRounds == engine.completedRounds)
            #expect(restored.drain().1.isEmpty)
        }
    }

    @Test(arguments: [RestPlanID.tickrest, .eye202020, .fiftyTen, .pomodoro], BreakStartMode.allCases)
    func pausedPartialRestSurvivesDiskRoundtripAndCompletesOnce(_ plan: RestPlanID,
                                                               _ mode: BreakStartMode) throws {
        try store { disk, _ in
            let s = settings(plan, mode: mode); let engine = Engine(settings: s); var time = now
            step(engine, s.shortInterval, &time)
            if mode == .manual { engine.start(now: time) }
            step(engine, 5, &time)
            let id = try #require(engine.reminder?.id)
            engine.setPause(.indefinite, now: time); step(engine, 60, &time)
            var saved = SavedData(); saved.settings = s; saved.snapshot = engine.snapshot(now: time)
            saved.records = engine.drain().1; try disk.save(saved)
            let loaded = disk.load()
            let restored = Engine(settings: loaded.settings, snapshot: loaded.snapshot, now: time)
            #expect(restored.pause == .indefinite && restored.reminder?.elapsed == 5)
            #expect(restored.reminder?.id == id)
            restored.setPause(nil, now: time); step(restored, 30, &time); step(restored, 1, &time)
            if mode == .manual { restored.start(now: time) }
            step(restored, s.shortDuration - 5, &time)
            DataStore.append(restored.drain().1, to: &saved.records, now: time)
            let summary = TodaySummary(records: saved.records, now: time)
            #expect(summary.rest == s.shortDuration && summary.completed == 1)
            #expect(saved.records.filter { $0.outcome == .completed }.first?.reminderID == id)
        }
    }

    @Test(arguments: [RestPlanID.tickrest, .eye202020, .fiftyTen, .pomodoro])
    func zeroPostponementLimitAndDoubleSkipCannotDuplicateOutcomes(_ plan: RestPlanID) {
        var s = settings(plan); s.postponeLimit = 0
        let engine = Engine(settings: s); var time = now
        step(engine, s.shortInterval, &time); let id = engine.reminder?.id
        engine.postpone(now: time)
        #expect(engine.isResting && engine.reminder?.id == id)
        engine.skip(now: time); engine.skip(now: time)
        #expect(engine.records.filter { $0.outcome == .skipped }.count == 1)
        #expect(engine.records.allSatisfy { $0.outcome != .postponed && $0.outcome != .completed })
    }

    @Test(arguments: [RestPlanID.tickrest, .eye202020, .fiftyTen, .pomodoro])
    func cancelledPendingPlanStaysCancelledAfterRestart(_ plan: RestPlanID) throws {
        let s = settings(plan); let engine = Engine(settings: s); var time = now
        step(engine, s.shortInterval, &time)
        engine.applyPlan(.preset(plan == .fiftyTen ? .eye202020 : .fiftyTen), now: time)
        #expect(engine.pendingPlan != nil)
        engine.cancelPendingPlan()
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(engine.snapshot(now: time)))
        let restored = Engine(settings: s, snapshot: snapshot, now: time)
        #expect(restored.settings.restPlan == s.restPlan && restored.pendingPlan == nil)
        #expect(restored.records.filter { $0.outcome == .planChanged }.isEmpty)
    }

    @Test(arguments: [RestPlanID.tickrest, .eye202020, .fiftyTen, .pomodoro])
    func pendingSwitchKeepsOldStatisticsContextUntilBoundary(_ plan: RestPlanID) {
        let s = settings(plan); let engine = Engine(settings: s); var time = now
        step(engine, s.shortInterval, &time)
        let destination: RestPlanID = plan == .fiftyTen ? .eye202020 : .fiftyTen
        engine.applyPlan(.preset(destination), now: time)
        step(engine, s.shortDuration, &time); step(engine, 10, &time)
        let completion = engine.records.first { $0.outcome == .completed }
        #expect(completion?.planID == plan && completion?.timingModel == s.timingModel)
        #expect(engine.settings.planID == destination && engine.pendingPlan == nil)
        #expect(engine.records.last?.planID == destination && engine.records.last?.seconds == 10)
        #expect(engine.records.filter { $0.outcome == .planChanged }.count == 1)
    }

    @Test(arguments: [RestPlanID.eye202020, .fiftyTen, .pomodoro], [-0.001, 0.0, 0.001])
    func naturalRestQualificationExactBoundary(_ plan: RestPlanID, _ offset: Double) {
        let s = settings(plan); let engine = Engine(settings: s); var time = now
        step(engine, 100, &time); engine.beginAway(at: time)
        time = time.addingTimeInterval(s.shortDuration + offset)
        engine.endAway(now: time, minimumShort: s.shortDuration)
        #expect(engine.shortElapsed == (offset < 0 ? 100 : 0))
        #expect(engine.completedRounds == 0)
        let summary = TodaySummary(records: engine.records, now: time)
        #expect(abs(summary.natural - (s.shortDuration + offset)) < 0.00001)
        #expect(summary.rest == 0 && summary.completed == 0 && summary.usage == 100)
    }

    @Test(arguments: Array(1...7), [false, true])
    func workScheduleHandlesEveryWeekdayAndOvernightBoundary(_ weekday: Int, _ overnight: Bool) {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let sunday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 11))!
        let day = calendar.date(byAdding: .day, value: weekday - 1, to: sunday)!
        var s = Settings(); s.scheduleEnabled = true; s.weekdays = [weekday]
        s.scheduleStart = overnight ? 22 * 60 : 9 * 60; s.scheduleEnd = overnight ? 6 * 60 : 18 * 60
        let start = calendar.date(byAdding: .minute, value: s.scheduleStart, to: day)!
        let endDay = overnight ? calendar.date(byAdding: .day, value: 1, to: day)! : day
        let end = calendar.date(byAdding: .minute, value: s.scheduleEnd, to: endDay)!
        #expect(!s.isWorkingTime(start.addingTimeInterval(-1), calendar: calendar))
        #expect(s.isWorkingTime(start, calendar: calendar))
        #expect(s.isWorkingTime(end.addingTimeInterval(-1), calendar: calendar))
        #expect(!s.isWorkingTime(end, calendar: calendar))
        #expect(!s.isWorkingTime(start.addingTimeInterval(2 * 86400), calendar: calendar))
    }

    @Test func negativeElapsedInputDoesNotCreateTimeOrAdvanceReminder() {
        let engine = Engine(settings: settings(.eye202020)); var time = now
        step(engine, 1200, &time)
        let before = engine.snapshot(now: time); _ = engine.drain()
        engine.tick(seconds: -100, now: time)
        #expect(engine.reminder == before.activeReminder)
        #expect(engine.records.isEmpty && engine.effects.isEmpty)
    }

    // AUDIT-01: a manual rest started outside work hours must finish normally or
    // be explicitly interrupted and hidden; never silently orphan its window.
    @Test func scheduleOpeningDoesNotSilentlyDiscardAnActiveManualRest() throws {
        var s = settings(.fiftyTen); s.scheduleEnabled = true; s.weekdays = [2]
        var time = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 8, minute: 59, second: 40))!
        let engine = Engine(settings: s); engine.tick(seconds: 0, now: time)
        engine.startNow(.short, now: time); step(engine, 10, &time)
        let id = try #require(engine.reminder?.id); _ = engine.drain()
        step(engine, 10, &time)
        if !engine.isResting {
            #expect(engine.effects.contains(.hide), "A cancelled rest must close its panel")
            #expect(engine.records.contains { $0.outcome == .interrupted && $0.reminderID == id },
                    "A cancelled measured rest must have an interruption outcome")
        } else { #expect(engine.reminder?.id == id && engine.reminder?.elapsed == 20) }
    }

    @Test(arguments: [RestPlanID.tickrest, .eye202020, .fiftyTen, .pomodoro], [false, true])
    func scheduleOpeningPreservesManualBreakAndPendingPlan(_ plan: RestPlanID, _ paused: Bool) throws {
        var s = settings(plan); s.scheduleEnabled = true; s.weekdays = [2]
        var time = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 8, minute: 59, second: 58))!
        let engine = Engine(settings: s); engine.tick(seconds: 0, now: time)
        engine.startNow(.short, now: time); step(engine, 1, &time)
        engine.applyPlan(.preset(.fiftyTen), now: time)
        let before = try #require(engine.reminder)
        if paused { engine.setPause(.indefinite, now: time) }
        _ = engine.drain(); step(engine, 1, &time)
        #expect(engine.reminder?.id == before.id)
        #expect(engine.reminder?.elapsed == (paused ? 1 : 2))
        #expect(engine.pendingPlan == .preset(.fiftyTen))
        #expect(engine.settings.restPlan == s.restPlan)
        #expect(!engine.effects.contains(.hide))
        #expect(engine.records.allSatisfy { $0.outcome == .usage })
    }

    // AUDIT-02: startup/wake grace is 30 seconds from return, and runs concurrently
    // with a longer postponement. The menu already displays max(delay, grace).
    @Test(arguments: ["restart", "away", "pause"])
    func recoveryGraceDoesNotExtendAnAlreadyLongerPostponement(_ recovery: String) throws {
        let s = settings(.eye202020, mode: .manual); var engine = Engine(settings: s); var time = now
        step(engine, 1200, &time); engine.postpone(now: time)
        let id = try #require(engine.reminder?.id)
        switch recovery {
        case "restart":
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(engine.snapshot(now: time)))
            time = time.addingTimeInterval(10); engine = Engine(settings: s, snapshot: snapshot, now: time)
        case "away":
            engine.beginAway(at: time); time = time.addingTimeInterval(1)
            engine.endAway(now: time, minimumShort: s.shortDuration)
        default:
            engine.setPause(.indefinite, now: time); time = time.addingTimeInterval(10)
            engine.setPause(nil, now: time)
        }
        _ = engine.drain()
        for _ in 0..<Int(s.singlePostpone) { step(engine, 1, &time) }
        step(engine, 1, &time) // Permit the scheduler's documented next-tick presentation.
        #expect(engine.graceRemaining == 0, "Recovery grace must expire during the postponement")
        if case .waiting(let r) = engine.phase { #expect(r.id == id && r.postponements == 1) }
        else { Issue.record("The promised postponement has expired, but the reminder is still hidden") }
    }

    // AUDIT-03: pausing does not erase measured rest; natural rest must be combined
    // with that same partial rest even though pause wrapped it as deferred.
    @Test(arguments: [RestPlanID.eye202020, .fiftyTen, .pomodoro])
    func naturalRestCanSatisfyTheRemainderOfAPausedRest(_ plan: RestPlanID) {
        let s = settings(plan); let engine = Engine(settings: s); var time = now
        step(engine, s.shortInterval, &time); step(engine, s.shortDuration - 1, &time)
        engine.setPause(.indefinite, now: time); engine.beginAway(at: time)
        time = time.addingTimeInterval(1); engine.endAway(now: time, minimumShort: s.shortDuration)
        #expect(engine.reminder == nil && engine.roundRestKind == nil,
                "Measured partial rest plus natural rest has met the target")
        #expect(engine.remaining(.short) == s.shortInterval)
        #expect(engine.pause == .indefinite)
        let summary = TodaySummary(records: engine.records, now: time)
        #expect(summary.rest == s.shortDuration - 1 && summary.natural == 1 && summary.completed == 0)
    }

    // AUDIT-04: changing a visual preference must not delay a due rest, the same
    // contract already covered for status-dot preferences in StatusDotTests.
    @Test(arguments: ["theme", "language", "countdown", "size", "sound", "scope"])
    func presentationPreferenceEditsDoNotDelayDueReminder(_ preference: String) {
        let s = settings(.eye202020); let engine = Engine(settings: s); var time = now
        step(engine, s.shortInterval - 1, &time)
        var edited = s
        switch preference {
        case "theme": edited.theme = .dark
        case "language": edited.language = "ja"
        case "countdown": edited.showCountdown = false
        case "size": edited.gentleReminderSize = .mini
        case "sound": edited.sound = true
        default: edited.displayScope = .current
        }
        engine.updateSettings(edited); step(engine, 1, &time)
        #expect(engine.isResting && engine.reminder?.kind == .short,
                "Presentation changes must preserve the scheduled rest deadline")
    }

    // AUDIT-05: syntactically valid JSON can still contain a damaged scheduler
    // state. Reject it and preserve the bytes just like invalid settings.
    @Test(arguments: ["negative-usage", "negative-cooldown", "negative-delay", "zero-target",
                      "elapsed-over-target", "negative-budget", "disabled-kind"])
    func invalidSnapshotIsRejectedAndOriginalFilePreserved(_ scenario: String) throws {
        try store { disk, _ in
            var saved = SavedData(); saved.settings = settings(.eye202020)
            saved.snapshot.savedAt = now
            switch scenario {
            case "negative-usage": saved.snapshot.shortElapsed = -100
            case "negative-cooldown": saved.snapshot.shortCooldown = -10
            default:
                var r = Reminder(kind: scenario == "disabled-kind" ? .long : .short,
                                 target: scenario == "zero-target" ? 0 : 20)
                if scenario == "elapsed-over-target" { r.elapsed = 21 }
                if scenario == "negative-budget" { r.postponements = -1 }
                saved.snapshot.deferredReminder = r
                saved.snapshot.deferredRemaining = scenario == "negative-delay" ? -10 : 0
            }
            try disk.save(saved); let original = try Data(contentsOf: disk.url)
            _ = disk.load()
            #expect(disk.loadErrorKey == "error.load", "Invalid persisted scheduler state must be rejected")
            let backups = try FileManager.default.contentsOfDirectory(at: disk.url.deletingLastPathComponent(),
                                                                     includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("state-damaged-") }
            #expect(backups.count == 1)
            if let backup = backups.first { #expect(try Data(contentsOf: backup) == original) }
        }
    }
}
