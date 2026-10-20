import Foundation
import Testing
@testable import TickRestCore

private let planNow = Date(timeIntervalSince1970: 1_800_000_000)
private func planSettings(_ id: RestPlanID, manual: Bool = false) -> Settings {
    var s = Settings(); s.restPlan = .preset(id); s.prewarning = 0
    s.breakStartMode = manual ? .manual : .automatic
    return s
}
private func step(_ engine: Engine, _ seconds: Double, _ date: inout Date) {
    date = date.addingTimeInterval(seconds); engine.tick(seconds: seconds, now: date)
}

extension EngineTests {
    @Test(arguments: RestPlanID.allCases)
    func planPresetsValidateAndRoundtrip(_ id: RestPlanID) throws {
        let settings = planSettings(id)
        #expect(settings.validationError == nil)
        #expect(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings)) == settings)
    }

    @Test(arguments: [RestPlanID.eye202020, .fiftyTen])
    func singlePlanCompletesAndRestartsFullWorkInterval(_ id: RestPlanID) {
        let s = planSettings(id); let e = Engine(settings: s); var now = planNow
        step(e, s.shortInterval - 1, &now); #expect(e.reminder == nil)
        step(e, 1, &now); #expect(e.isResting && e.reminder?.kind == .short)
        step(e, s.shortDuration, &now)
        #expect(!e.isResting && e.remaining(.short) == s.shortInterval)
        #expect(TodaySummary(records: e.records, now: now).completed == 1)
        #expect(e.longElapsed == 0 && e.displayKinds == [.short])
    }

    @Test func tickrestNormalSequenceKeepsIndependentLongTimer() {
        let e = Engine(settings: planSettings(.tickrest)); var now = planNow
        for _ in 0..<2 {
            step(e, 1200, &now); #expect(e.reminder?.kind == .short)
            let priorLong = e.longElapsed; step(e, 20, &now)
            #expect(e.shortElapsed == 0 && e.longElapsed == priorLong)
        }
        step(e, 1200, &now); #expect(e.reminder?.kind == .long)
        step(e, 300, &now); #expect(e.shortElapsed == 0 && e.longElapsed == 0)
        #expect(TodaySummary(records: e.records, now: now).completed == 3)
    }

    @Test(arguments: BreakStartMode.allCases)
    func pomodoroTwoFullSetsHaveExactlyEightFocusSessions(_ mode: BreakStartMode) {
        let s = planSettings(.pomodoro, manual: mode == .manual); let e = Engine(settings: s); var now = planNow
        for _ in 0..<2 {
            for round in 1...4 {
                step(e, 1500, &now)
                #expect(e.completedRounds == round && e.roundRestKind == (round == 4 ? .long : .short))
                #expect(e.reminder?.kind == (round == 4 ? .long : .short))
                if mode == .manual {
                    step(e, 25, &now)
                    #expect(e.completedRounds == round && !e.isResting)
                    e.start(now: now)
                }
                step(e, round == 4 ? 900 : 300, &now)
                #expect(e.roundRestKind == nil && e.remaining(.short) == 1500)
            }
            #expect(e.completedRounds == 0)
        }
        let summary = TodaySummary(records: e.records, now: now)
        #expect(summary.focusCompleted == 8 && summary.completed == 8)
    }

    @Test func suppressedPomodoroCompletesFocusOnlyOnceBeforePresenting() {
        let e = Engine(settings: planSettings(.pomodoro)); var now = planNow
        e.setSuppressed(true); step(e, 1500, &now); step(e, 5000, &now)
        #expect(e.completedRounds == 1 && e.reminder == nil && e.roundRestKind == .short)
        #expect(e.records.filter { $0.outcome == .focusCompleted }.count == 1)
        e.setSuppressed(false); step(e, 30, &now); step(e, 1, &now)
        #expect(e.isResting && e.completedRounds == 1)
    }

    @Test func pomodoroPostponeAndSkipNeverDuplicateFocusCount() throws {
        let e = Engine(settings: planSettings(.pomodoro)); var now = planNow
        step(e, 1500, &now); let id = try #require(e.reminder?.id)
        for count in 1...2 {
            e.postpone(now: now); step(e, 120, &now)
            #expect(e.completedRounds == 1 && e.reminder?.postponements == count && e.reminder?.id == id)
        }
        e.skip(now: now)
        #expect(e.completedRounds == 1 && e.roundRestKind == nil && e.remaining(.short) == 1500)
        #expect(e.records.filter { $0.outcome == .focusCompleted }.count == 1)
        #expect(!e.records.contains { $0.outcome == .completed })
    }

    @Test func pomodoroEarlyEndRetriesFullRestWithoutStartingNextFocus() {
        let e = Engine(settings: planSettings(.pomodoro)); var now = planNow
        step(e, 1500, &now); step(e, 150, &now); e.finish(now: now)
        #expect(e.completedRounds == 1 && e.roundRestKind == .short && e.remaining(.short) == 120)
        step(e, 119, &now); #expect(e.reminder == nil && e.shortElapsed == 1500)
        step(e, 1, &now); #expect(e.reminder?.elapsed == 0 && e.reminder?.target == 300)
        step(e, 300, &now); #expect(e.completedRounds == 1 && e.roundRestKind == nil)
        #expect(TodaySummary(records: e.records, now: now).rest == 450)
    }

    @Test func skipFourthBreakStartsNewSetWithoutCompletingBreak() {
        let e = Engine(settings: planSettings(.pomodoro)); var now = planNow
        for _ in 0..<3 { step(e, 1500, &now); e.skip(now: now) }
        step(e, 1500, &now); #expect(e.roundRestKind == .long)
        e.skip(now: now)
        #expect(e.focusRound == 1 && e.completedRounds == 0 && e.roundRestKind == nil)
        #expect(TodaySummary(records: e.records, now: now).completed == 0)
    }

    @Test func manualPomodoroBreakDoesNotManufactureFocusCompletion() {
        let e = Engine(settings: planSettings(.pomodoro)); var now = planNow
        step(e, 200, &now); e.startNow(.short, now: now); step(e, 300, &now)
        #expect(e.completedRounds == 0 && e.shortElapsed == 0 && e.roundRestKind == nil)
        #expect(!e.records.contains { $0.outcome == .focusCompleted })
    }

    @Test func restartRoundKeepsEarlierRoundsAndRestartGroupClearsThem() {
        let e = Engine(settings: planSettings(.pomodoro)); var now = planNow
        step(e, 1500, &now); e.skip(now: now); step(e, 500, &now)
        e.restartFocus(group: false, now: now)
        #expect(e.completedRounds == 1 && e.shortElapsed == 0 && e.focusRound == 2)
        step(e, 1500, &now); e.restartFocus(group: true, now: now)
        #expect(e.completedRounds == 0 && e.roundRestKind == nil && e.reminder == nil)
        #expect(e.records.filter { $0.outcome == .focusCompleted }.count == 2)
    }

    @Test(arguments: ["complete", "skip", "end"])
    func pendingPlanAppliesOnlyAtRestBoundary(_ action: String) {
        let s = planSettings(.tickrest); let e = Engine(settings: s); var now = planNow
        step(e, 1200, &now); step(e, 3, &now)
        e.applyPlan(.preset(.pomodoro), now: now)
        #expect(e.settings.restPlan == s.restPlan && e.pendingPlan?.id == .pomodoro && e.isResting)
        switch action {
        case "complete": step(e, 17, &now)
        case "skip": e.skip(now: now)
        default: e.finish(now: now)
        }
        #expect(e.pendingPlan == nil && e.settings.planID == .pomodoro && e.remaining(.short) == 1500)
        #expect(e.shortElapsed == 0 && e.longElapsed == 0 && e.reminder == nil)
        #expect(e.records.filter { $0.outcome == .planChanged }.count == 1)
        #expect(e.records.filter { $0.outcome == .skipped }.count == (action == "skip" ? 1 : 0))
    }

    @Test func pendingPlanCanBeReplacedCancelledAndSurvivesPreferenceEdits() {
        let e = Engine(settings: planSettings(.tickrest)); var now = planNow
        step(e, 1200, &now); e.applyPlan(.preset(.pomodoro), now: now)
        var s = e.settings; s.sound = true; s.language = "ja"; e.updateSettings(s)
        #expect(e.pendingPlan?.id == .pomodoro)
        e.applyPlan(.preset(.fiftyTen), now: now); #expect(e.pendingPlan?.id == .fiftyTen)
        e.cancelPendingPlan(); step(e, 20, &now)
        #expect(e.settings.planID == .tickrest && e.settings.sound && e.settings.language == "ja")
    }

    @Test(arguments: ["working", "warning", "waiting", "deferred", "paused", "away", "outside"])
    func switchingClearsOldScheduleWithoutRecordingSkip(_ phase: String) {
        var s = planSettings(.tickrest, manual: true); s.sound = true; s.language = "ko"
        if phase == "warning" { s.prewarning = 10 }
        let e = Engine(settings: s); var now = planNow
        step(e, phase == "working" ? 100 : phase == "warning" ? 1195 : 1200, &now)
        if phase == "deferred" { e.postpone(now: now) }
        if phase == "paused" { e.setPause(.indefinite, now: now) }
        if phase == "away" { e.beginAway(at: now) }
        if phase == "outside" {
            var scheduled = e.settings; scheduled.scheduleEnabled = true; scheduled.weekdays = [Calendar.current.component(.weekday, from: now) % 7 + 1]
            e.updateSettings(scheduled); step(e, 1, &now)
        }
        e.applyPlan(.preset(.eye202020), now: now)
        #expect(e.settings.planID == .eye202020 && e.reminder == nil && e.pendingPlan == nil)
        #expect(e.remaining(.short) == 1200 && e.settings.sound && e.settings.language == "ko")
        #expect(!e.records.contains { $0.outcome == .skipped })
        if phase == "paused" { #expect(e.pause == .indefinite) }
        if phase == "away" { #expect(e.away) }
    }

    @Test func pendingPlanOnRestartAppliesOnceAndKeepsOtherPreferences() throws {
        var s = planSettings(.tickrest); s.sound = true
        let e = Engine(settings: s); var now = planNow
        step(e, 1200, &now); step(e, 3, &now); e.applyPlan(.preset(.fiftyTen), now: now)
        let data = try JSONEncoder().encode(e.snapshot(now: now))
        let snap = try JSONDecoder().decode(Snapshot.self, from: data)
        let restored = Engine(settings: s, snapshot: snap, now: now.addingTimeInterval(1000))
        #expect(restored.settings.planID == .fiftyTen && restored.settings.sound)
        #expect(restored.pendingPlan == nil && restored.remaining(.short) == 3000)
        #expect(restored.records.filter { $0.outcome == .planChanged }.count == 1)
        #expect(restored.records.allSatisfy { $0.planID == .tickrest })
    }

    @Test func pomodoroDeferredSnapshotPreservesRoundBudgetAndOfflineTime() throws {
        let s = planSettings(.pomodoro, manual: true); let e = Engine(settings: s); var now = planNow
        step(e, 1500, &now); e.postpone(now: now); step(e, 20, &now)
        let snap = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(e.snapshot(now: now)))
        let restored = Engine(settings: s, snapshot: snap, now: now.addingTimeInterval(10000))
        #expect(restored.completedRounds == 1 && restored.roundRestKind == .short)
        if case .deferred(let r, let remaining) = restored.phase {
            #expect(remaining == 100 && r.postponements == 1 && r.id == e.reminder?.id)
        } else { Issue.record("Expected preserved postponement") }
        step(restored, 100, &now); step(restored, 1, &now)
        #expect(restored.completedRounds == 1 && !restored.records.contains { $0.outcome == .focusCompleted })
    }

    @Test(arguments: [10.0, 300, 900])
    func pomodoroAwayDuringFocusNeverAddsCompletedRound(_ seconds: Double) {
        let e = Engine(settings: planSettings(.pomodoro)); var now = planNow
        step(e, 1500, &now); e.skip(now: now); step(e, 200, &now)
        e.beginAway(at: now); now = now.addingTimeInterval(seconds); e.endAway(now: now, minimumShort: 300)
        #expect(e.completedRounds == (seconds >= 900 ? 0 : 1))
        #expect(e.shortElapsed == (seconds >= 300 ? 0 : 200))
        #expect(e.records.filter { $0.outcome == .focusCompleted }.count == 1)
    }

    @Test(arguments: [RestPlanID.eye202020, .fiftyTen, .pomodoro])
    func enoughNaturalRestSatisfiesDueBreakWithoutCompletedTimerCount(_ id: RestPlanID) {
        let s = planSettings(id); let e = Engine(settings: s); var now = planNow
        step(e, s.shortInterval, &now); e.beginAway(at: now)
        now = now.addingTimeInterval(s.shortDuration); e.endAway(now: now, minimumShort: s.shortDuration)
        #expect(e.reminder == nil && e.roundRestKind == nil && e.remaining(.short) == s.shortInterval)
        let summary = TodaySummary(records: e.records, now: now)
        #expect(summary.completed == 0 && summary.natural == s.shortDuration)
    }

    @Test func insufficientAwayRetainsRestAndPendingPlanUntilCompleted() {
        let e = Engine(settings: planSettings(.pomodoro)); var now = planNow
        step(e, 1500, &now); step(e, 100, &now); e.applyPlan(.preset(.eye202020), now: now)
        e.beginAway(at: now); now = now.addingTimeInterval(10); e.endAway(now: now, minimumShort: 300)
        #expect(e.settings.planID == .pomodoro && e.pendingPlan?.id == .eye202020)
        #expect(e.reminder?.elapsed == 110)
        step(e, 30, &now); step(e, 1, &now); step(e, 190, &now)
        #expect(e.settings.planID == .eye202020 && e.pendingPlan == nil)
    }

    @Test func pauseDuringRestPreservesElapsedAndPendingPlan() {
        let e = Engine(settings: planSettings(.pomodoro)); var now = planNow
        step(e, 1500, &now); step(e, 80, &now); e.applyPlan(.preset(.fiftyTen), now: now)
        e.setPause(.indefinite, now: now); step(e, 600, &now)
        #expect(e.reminder?.elapsed == 80 && e.pendingPlan?.id == .fiftyTen && e.completedRounds == 1)
        e.setPause(nil, now: now); step(e, 30, &now); step(e, 1, &now); step(e, 220, &now)
        #expect(e.settings.planID == .fiftyTen && e.pendingPlan == nil)
    }

    @Test func customPostponementLimitAndEarlyEndCooldownAreIndependent() {
        var s = planSettings(.fiftyTen); s.singlePostpone = 60; s.postponeLimit = 0
        let e = Engine(settings: s); var now = planNow
        step(e, 3000, &now); e.postpone(now: now); #expect(e.isResting && e.reminder?.postponements == 0)
        step(e, 20, &now); e.finish(now: now); #expect(e.remaining(.short) == 60)
        step(e, 60, &now); #expect(e.isResting && e.reminder?.elapsed == 0)
    }

    @Test func legacyVersionOneMigrationPreservesProgressAndCreatesBackup() throws {
        for custom in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tickrest-migration-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = DataStore(url: directory.appendingPathComponent("state.json"))
            var data = SavedData(); data.version = 1; data.settings.sound = true
            if custom { data.settings.shortInterval = 1800 }
            data.snapshot.shortElapsed = 1000; data.snapshot.longElapsed = 3600; data.snapshot.longCooldown = 200
            data.snapshot.deferredReminder = Reminder(kind: .long, target: 300); data.snapshot.deferredRemaining = 42
            data.records = [Record(date: planNow, kind: .short, outcome: .completed)]
            let encoded = try JSONEncoder().encode(data)
            var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            var settings = try #require(object["settings"] as? [String: Any])
            for key in ["planID", "basePlanID", "timingModel", "rounds", "shortPostpone", "longPostpone", "singlePostpone", "postponeLimit"] { settings.removeValue(forKey: key) }
            object["settings"] = settings
            let legacy = try JSONSerialization.data(withJSONObject: object)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try legacy.write(to: store.url)
            let loaded = store.load()
            #expect(store.loadError == nil && loaded.version == 3)
            #expect(loaded.settings.planID == (custom ? .custom : .tickrest) && loaded.settings.sound)
            #expect(loaded.snapshot.shortElapsed == 1000 && loaded.snapshot.longCooldown == 200 && loaded.snapshot.deferredRemaining == 42)
            #expect(loaded.records.first?.planID == nil && loaded.records.count == 1)
            #expect(try Data(contentsOf: directory.appendingPathComponent("state-v1-backup.json")) == legacy)
            try store.save(loaded); #expect(store.load().settings == loaded.settings)
        }
    }

    @Test func recordsFromDifferentPlansNeverMergeAndCarryContext() {
        let e = Engine(settings: planSettings(.tickrest)); var now = planNow
        step(e, 5, &now); var records = e.drain().1
        e.applyPlan(.preset(.fiftyTen), now: now); step(e, 5, &now)
        DataStore.append(e.drain().1, to: &records, now: now)
        #expect(records.filter { $0.outcome == .usage }.map(\.planID) == [.tickrest, .fiftyTen])
        #expect(records.last?.timingModel == .single)
    }

    @Test func invalidRoutineCannotChangeActiveOrPendingSchedule() {
        let e = Engine(settings: planSettings(.tickrest)); var invalid = RestPlan.preset(.pomodoro)
        invalid.rounds = 0; e.applyPlan(invalid, now: planNow)
        #expect(e.settings.planID == .tickrest && e.pendingPlan == nil)
        invalid.rounds = 4; invalid.shortDuration = .nan; e.applyPlan(invalid, now: planNow)
        #expect(e.settings.planID == .tickrest)
    }
    @Test func futureRoutineIsAlsoValidatedWhenPreferencesChange() {
        let e = Engine(settings: planSettings(.tickrest)); var now = planNow
        step(e, 1200, &now)
        var pending = RestPlan.preset(.eye202020); pending.shortInterval = 60; pending.markCustom()
        e.applyPlan(pending, now: now)
        var changed = e.settings; changed.prewarning = 60; e.updateSettings(changed)
        #expect(e.settings.prewarning == 0 && e.pendingPlan == pending)
        step(e, 20, &now)
        #expect(e.settings.restPlan == pending && e.settings.validationError == nil)
    }

    @Test func customRoundCountAndDurationsControlLongBreakBoundary() {
        var s = planSettings(.pomodoro); s.rounds = 2; s.shortInterval = 60; s.shortDuration = 10; s.longDuration = 60
        var plan = s.restPlan; plan.markCustom(); s.restPlan = plan
        let e = Engine(settings: s); var now = planNow
        step(e, 60, &now); #expect(e.reminder?.kind == .short && e.reminder?.target == 10)
        step(e, 10, &now); step(e, 60, &now)
        #expect(e.reminder?.kind == .long && e.reminder?.target == 60)
        step(e, 60, &now); #expect(e.completedRounds == 0 && e.focusRound == 1)
        #expect(e.records.allSatisfy { $0.planID == .custom && $0.basePlanID == .pomodoro })
    }

    @Test func newWorkSessionResetsPomodoroSetWithoutCompletingFocus() {
        var s = planSettings(.pomodoro); s.scheduleEnabled = true; s.weekdays = Set(1...7)
        let calendar = Calendar.current
        var now = calendar.date(bySettingHour: 17, minute: 0, second: 0, of: planNow)!
        let e = Engine(settings: s)
        step(e, 1500, &now); e.skip(now: now); step(e, 100, &now)
        now = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: now)!; e.tick(seconds: 1, now: now)
        let usage = e.shortElapsed
        step(e, 3600, &now); #expect(e.shortElapsed == usage && e.outsideSchedule)
        now = calendar.date(byAdding: .day, value: 1, to: now)!
        now = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: now)!; e.tick(seconds: 1, now: now)
        #expect(e.completedRounds == 0 && e.roundRestKind == nil && e.shortElapsed == 1)
        #expect(e.records.filter { $0.outcome == .focusCompleted }.count == 1)
    }

    @Test(arguments: ["en", "zh-Hans", "zh-Hant", "ja", "ko"])
    func planNamesAndRoundMessagesResolveInEveryLanguage(_ language: String) {
        L10n.language = language
        defer { L10n.language = "zh-Hans" }
        for plan in RestPlanID.allCases {
            #expect(!plan.title.hasPrefix("plan.") && !plan.description.hasPrefix("plan."))
        }
        for model in TimingModel.allCases { #expect(!model.title.hasPrefix("timing.")) }
        #expect(L10n.duration(300) == L10n.text("duration.minutes", 5))
        let e = Engine(settings: planSettings(.pomodoro)); var now = planNow
        step(e, 100, &now)
        #expect(ReminderDisplay(engine: e).stateText == L10n.text("plan.focus_state", 1, 4))
        #expect(ReminderDisplay(engine: e).countdownText(for: .short).contains("23:20"))
        step(e, 1400, &now)
        #expect(e.reminder?.title == L10n.text("plan.short_break"))
        let eye = Engine(settings: planSettings(.eye202020)); step(eye, 1200, &now)
        #expect(eye.reminder?.idea == L10n.text("plan.eye_idea"))
    }

    @Test(arguments: [RestPlanID.eye202020, .fiftyTen, .pomodoro])
    func reminderPreviewUsesTheActiveRoutineWithoutChangingEngine(_ id: RestPlanID) {
        let s = planSettings(id); let e = Engine(settings: s)
        let preview = s.previewReminder
        #expect(preview.target == 5 && preview.planID == id)
        #expect(preview.title == s.breakTitle(.short))
        #expect(preview.idea == L10n.text(id == .eye202020 ? "plan.eye_idea" : "plan.movement_idea"))
        #expect(e.reminder == nil && e.records.isEmpty && e.completedRounds == 0)
    }

}
