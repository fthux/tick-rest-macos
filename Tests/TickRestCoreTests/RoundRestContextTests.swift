import Foundation
import Testing
@testable import TickRestCore

private let contextNow = Date(timeIntervalSince1970: 1_800_000_000)

private func contextSettings(_ mode: BreakStartMode = .automatic) -> Settings {
    var settings = Settings()
    settings.restPlan = .preset(.pomodoro)
    settings.prewarning = 0
    settings.breakStartMode = mode
    return settings
}

private func advance(_ engine: Engine, _ seconds: Double, _ now: inout Date) {
    now = now.addingTimeInterval(seconds)
    engine.tick(seconds: seconds, now: now)
}

private func beginRound(_ round: Int, engine: Engine, now: inout Date) {
    for _ in 1..<round {
        advance(engine, engine.settings.shortInterval, &now)
        engine.skip(now: now)
    }
}

// Keep localization assertions in the existing serialized core suite.
extension EngineTests {
    @Test(arguments: Array(1...4), [BreakKind.short, .long])
    func midFocusSkipPreservesRoundAndRemainingTime(_ round: Int, _ kind: BreakKind) throws {
        let settings = contextSettings()
        let engine = Engine(settings: settings)
        var now = contextNow
        beginRound(round, engine: engine, now: &now)
        advance(engine, 200, &now)
        engine.startNow(kind, now: now)
        let id = try #require(engine.reminder?.id)
        advance(engine, 10, &now)
        let display = ReminderDisplay(engine: engine)
        #expect(engine.isMidFocusRest && engine.focusRound == round)
        #expect(display.roundRestText == L10n.text("plan.rest_mid_focus", round, 4))
        #expect(display.skipResultText == L10n.text("plan.skip_resume_focus", round, "21:40"))

        engine.skip(now: now)
        #expect(engine.phase == .working && engine.reminder == nil && engine.roundRestKind == nil)
        #expect(engine.focusRound == round && engine.completedRounds == round - 1)
        #expect(engine.shortElapsed == 200 && engine.remaining(.short) == 1300)
        #expect(display.skipResultText == nil)
        #expect(display.stateText == L10n.text("plan.focus_state", round, 4))
        #expect(display.countdownText(for: engine.displayKinds[0]) == L10n.text("plan.focus_remaining", round, 4, "21:40"))
        #expect(engine.records.filter { $0.outcome == .focusCompleted }.count == round - 1)
        let skip = try #require(engine.records.last { $0.outcome == .skipped })
        #expect(skip.reminderID == id && skip.seconds == 0)
        #expect(TodaySummary(records: engine.records, now: now).rest == 10)
        #expect(!engine.records.contains { $0.outcome == .completed })

        advance(engine, 1299, &now)
        #expect(engine.reminder == nil && engine.focusRound == round)
        advance(engine, 1, &now)
        #expect(engine.completedRounds == round && engine.focusRound == round && !engine.isMidFocusRest)
        #expect(engine.reminder?.kind == (round == 4 ? .long : .short))
        #expect(engine.records.filter { $0.outcome == .focusCompleted }.count == round)
    }

    @Test(arguments: [0.0, 1499.0])
    func midFocusSkipAtIntervalEdgesDoesNotCompleteFocus(_ elapsed: Double) {
        let engine = Engine(settings: contextSettings())
        var now = contextNow
        advance(engine, elapsed, &now)
        engine.startNow(.short, now: now)
        #expect(engine.isMidFocusRest && engine.focusRound == 1)
        engine.skip(now: now)
        #expect(engine.shortElapsed == elapsed && engine.remaining(.short) == 1500 - elapsed)
        #expect(engine.completedRounds == 0)
        #expect(!engine.records.contains { $0.outcome == .focusCompleted })
    }

    @Test(arguments: BreakStartMode.allCases, ["waiting", "running", "deferred"])
    func dueRestSkipStartsNextFullFocus(_ mode: BreakStartMode, _ stage: String) {
        let engine = Engine(settings: contextSettings(mode))
        var now = contextNow
        beginRound(2, engine: engine, now: &now)
        advance(engine, 1500, &now)
        if stage == "running" { engine.start(now: now); advance(engine, 10, &now) }
        if stage == "deferred" { engine.postpone(now: now); advance(engine, 5, &now) }
        let display = ReminderDisplay(engine: engine)
        #expect(!engine.isMidFocusRest && engine.focusRound == 2)
        #expect(display.roundRestText == L10n.text("plan.rest_after_focus", 2, 4))
        #expect(display.skipResultText == L10n.text("plan.skip_next_focus", 3, "25:00"))
        engine.skip(now: now)
        #expect(engine.phase == .working && engine.roundRestKind == nil && engine.reminder == nil)
        #expect(engine.focusRound == 3 && engine.completedRounds == 2 && engine.remaining(.short) == 1500)
        #expect(engine.records.filter { $0.outcome == .focusCompleted }.count == 2)
        advance(engine, 1, &now)
        #expect(engine.remaining(.short) == 1499 && engine.reminder == nil)
    }

    @Test(arguments: BreakStartMode.allCases, [false, true])
    func finalDueRestSkipStartsNewGroup(_ mode: BreakStartMode, _ started: Bool) {
        let engine = Engine(settings: contextSettings(mode))
        var now = contextNow
        beginRound(4, engine: engine, now: &now)
        advance(engine, 1500, &now)
        if started { engine.start(now: now); advance(engine, 400, &now) }
        #expect(engine.focusRound == 4 && engine.roundRestKind == .long && !engine.isMidFocusRest)
        #expect(ReminderDisplay(engine: engine).skipResultText == L10n.text("plan.skip_new_group", "25:00"))
        engine.skip(now: now)
        #expect(engine.focusRound == 1 && engine.completedRounds == 0 && engine.remaining(.short) == 1500)
        #expect(engine.records.filter { $0.outcome == .focusCompleted }.count == 4)
        #expect(!engine.records.contains { $0.outcome == .completed })
    }

    @Test(arguments: [BreakKind.short, .long])
    func postponedMidFocusSkipKeepsInterruptedFocus(_ kind: BreakKind) {
        let engine = Engine(settings: contextSettings())
        var now = contextNow
        beginRound(2, engine: engine, now: &now)
        advance(engine, 200, &now)
        engine.startNow(kind, now: now)
        advance(engine, 10, &now)
        engine.postpone(now: now)
        advance(engine, 20, &now)
        #expect(engine.isMidFocusRest && engine.focusRound == 2 && engine.shortElapsed == 200)
        #expect(ReminderDisplay(engine: engine).skipResultText == L10n.text("plan.skip_resume_focus", 2, "21:40"))
        engine.skip(now: now)
        #expect(engine.completedRounds == 1 && engine.focusRound == 2 && engine.remaining(.short) == 1300)
        advance(engine, 1, &now)
        #expect(engine.remaining(.short) == 1299 && engine.reminder == nil)
        #expect(TodaySummary(records: engine.records, now: now).rest == 10)
    }

    @Test(arguments: ["active", "deferred"], [BreakKind.short, .long])
    func restartingMidFocusRestRetainsRoundContext(_ stage: String, _ kind: BreakKind) throws {
        let settings = contextSettings()
        let engine = Engine(settings: settings)
        var now = contextNow
        beginRound(4, engine: engine, now: &now)
        advance(engine, 200, &now)
        engine.startNow(kind, now: now)
        advance(engine, kind == .long ? 400 : 10, &now)
        if stage == "deferred" { engine.postpone(now: now) }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(engine.snapshot(now: now)))
        now = now.addingTimeInterval(1000)
        let restored = Engine(settings: settings, snapshot: snapshot, now: now)
        #expect(restored.isMidFocusRest && restored.focusRound == 4 && restored.completedRounds == 3)
        #expect(restored.shortElapsed == 200)
        // Startup grace and postponed reminders expire without advancing focus.
        advance(restored, settings.postponement(kind) + 30, &now)
        advance(restored, 1, &now)
        #expect(restored.reminder?.kind == kind && restored.isMidFocusRest && restored.focusRound == 4)
        #expect(ReminderDisplay(engine: restored).skipResultText == L10n.text("plan.skip_resume_focus", 4, "21:40"))
        restored.skip(now: now)
        #expect(restored.focusRound == 4 && restored.completedRounds == 3 && restored.remaining(.short) == 1300)
    }

    @Test(arguments: ["active", "waiting", "deferred"], [2, 4])
    func restartingDueRestNeverMisclassifiesCompletedFocus(_ stage: String, _ round: Int) throws {
        let settings = contextSettings(stage == "waiting" ? .manual : .automatic)
        let engine = Engine(settings: settings)
        var now = contextNow
        beginRound(round, engine: engine, now: &now)
        advance(engine, 1500, &now)
        if stage == "active" { advance(engine, round == 4 ? 400 : 10, &now) }
        if stage == "deferred" { engine.postpone(now: now) }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(engine.snapshot(now: now)))
        now = now.addingTimeInterval(1000)
        let restored = Engine(settings: settings, snapshot: snapshot, now: now)
        #expect(!restored.isMidFocusRest && restored.focusRound == round && restored.shortElapsed == 1500)
        advance(restored, settings.postponement(round == 4 ? .long : .short) + 30, &now)
        advance(restored, 1, &now)
        #expect(restored.reminder != nil && !restored.isMidFocusRest)
        #expect(ReminderDisplay(engine: restored).roundRestText == L10n.text("plan.rest_after_focus", round, 4))
        restored.skip(now: now)
        #expect(restored.focusRound == (round == 4 ? 1 : 3))
        #expect(restored.completedRounds == (round == 4 ? 0 : 2) && restored.remaining(.short) == 1500)
    }

    @Test(arguments: [true, false])
    func skipHintMatchesPendingPlanTransition(_ midFocus: Bool) throws {
        let engine = Engine(settings: contextSettings())
        var now = contextNow
        advance(engine, midFocus ? 200 : 1500, &now)
        if midFocus { engine.startNow(.short, now: now) }
        engine.applyPlan(.preset(.fiftyTen), now: now)
        let pending = try #require(engine.pendingPlan)
        #expect(ReminderDisplay(engine: engine).skipResultText == L10n.text("plan.skip_apply_plan", pending.title))
        engine.skip(now: now)
        #expect(engine.settings.planID == .fiftyTen && engine.pendingPlan == nil)
        #expect(engine.completedRounds == 0 && engine.reminder == nil && engine.remaining(.short) == 3000)
    }

    @Test(arguments: [RestPlanID.tickrest, .eye202020, .fiftyTen], BreakStartMode.allCases)
    func nonRoundSkipStillStartsFullWorkInterval(_ plan: RestPlanID, _ mode: BreakStartMode) {
        var settings = contextSettings(mode)
        settings.restPlan = .preset(plan)
        let engine = Engine(settings: settings)
        var now = contextNow
        advance(engine, settings.shortInterval, &now)
        #expect(!engine.isMidFocusRest && ReminderDisplay(engine: engine).skipResultText == nil)
        engine.skip(now: now)
        #expect(engine.phase == .working && engine.reminder == nil && engine.remaining(.short) == settings.shortInterval)
        #expect(engine.completedRounds == 0 && engine.roundRestKind == nil)
        if plan == .tickrest { #expect(engine.longElapsed == settings.shortInterval) }
        #expect(!engine.records.contains { $0.outcome == .completed })
    }

    @Test(arguments: ["en", "zh-Hans", "zh-Hant", "ja", "ko"])
    func restContextAndSkipMessagesResolveInEveryLanguage(_ language: String) {
        L10n.language = language
        defer { L10n.language = "zh-Hans" }
        for key in ["plan.rest_mid_focus", "plan.rest_after_focus", "plan.skip_resume_focus",
                    "plan.skip_next_focus", "plan.skip_new_group", "plan.skip_apply_plan", "rest.skip_result"] {
            #expect(L10n.text(key) != key)
        }
        let engine = Engine(settings: contextSettings())
        var now = contextNow
        beginRound(2, engine: engine, now: &now)
        advance(engine, 200, &now)
        engine.startNow(.short, now: now)
        let display = ReminderDisplay(engine: engine)
        #expect(display.roundRestText == L10n.text("plan.rest_mid_focus", 2, 4))
        #expect(display.skipResultText == L10n.text("plan.skip_resume_focus", 2, "21:40"))
        #expect(L10n.text("rest.skip_result", display.skipResultText!).contains("21:40"))
    }
}
