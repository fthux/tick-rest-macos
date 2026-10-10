import Testing
import Foundation
@testable import TickRestCore

@Suite(.serialized)
struct EngineTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func engine(_ style: ReminderStyle = .gentle) -> Engine {
        var settings = Settings(); settings.style = style; settings.prewarning = 0
        return Engine(settings: settings)
    }
    @Test func testWaitingCardDoesNotCountRest() {
        let e = engine(); e.tick(seconds: 1200, now: now)
        guard case .waiting = e.phase else { Issue.record("Card should await explicit start"); return }
        e.tick(seconds: 30, now: now.addingTimeInterval(30))
        let summary = TodaySummary(records: e.records, now: now)
        #expect(summary.rest == 0); #expect(summary.completed == 0)
    }
    @Test func testShortCompletionPreservesLongUsage() {
        let e = engine(.overlay); e.tick(seconds: 1200, now: now)
        e.tick(seconds: 20, now: now.addingTimeInterval(20))
        #expect(e.shortElapsed == 0); #expect(e.longElapsed == 1200)
        #expect(TodaySummary(records: e.records, now: now).rest == 20)
        #expect(TodaySummary(records: e.records, now: now).completed == 1)
    }
    @Test func testLongReplacesSimultaneousShort() {
        let e = engine(); e.tick(seconds: 3600, now: now)
        #expect(e.reminder?.kind == .long)
        #expect(e.effects.filter { if case .show = $0 { return true }; return false }.count == 1)
        e.start(now: now); e.tick(seconds: 300, now: now.addingTimeInterval(300))
        #expect(e.shortElapsed == 0); #expect(e.longElapsed == 0)
        #expect(e.remaining(.short) == 1200); #expect(e.remaining(.long) == 3600)
        #expect(e.nextKind == .short)
    }
    @Test func testLongEndsEarlyCreditsOnlyShortAndAvoidsImmediateRepeat() {
        let e = engine(.overlay); e.tick(seconds: 3600, now: now)
        e.tick(seconds: 30, now: now.addingTimeInterval(30)); e.finish(now: now.addingTimeInterval(30))
        #expect(e.shortElapsed == 0); #expect(e.longElapsed == 3600)
        e.tick(seconds: 1, now: now.addingTimeInterval(31))
        #expect(e.reminder == nil)
        #expect(e.remaining(.short) == 1199); #expect(e.remaining(.long) == 299)
        #expect(e.nextKind == .long); #expect(L10n.clock(e.remaining(.long)) == "04:59")
        let summary = TodaySummary(records: e.records, now: now)
        #expect(summary.rest == 30); #expect(summary.completed == 0); #expect(summary.ended == 1)
        e.tick(seconds: 298, now: now.addingTimeInterval(329))
        #expect(e.remaining(.long) == 1); #expect(e.reminder == nil)
        e.tick(seconds: 1, now: now.addingTimeInterval(330))
        #expect(e.remaining(.long) == 0); #expect(e.reminder?.kind == .long)
    }
    @Test(arguments: [0.0, 1, 19])
    func testLongEndsQuicklyDoesNotReplaceWaitingShortDuringCooldown(_ restSeconds: Double) {
        let e = engine(); e.tick(seconds: 3600, now: now); e.start(now: now)
        let endedAt = now.addingTimeInterval(restSeconds)
        e.tick(seconds: restSeconds, now: endedAt); e.finish(now: endedAt)
        e.tick(seconds: 1, now: endedAt.addingTimeInterval(1))
        guard let short = e.reminder, short.kind == .short else {
            Issue.record("Due short reminder should follow insufficient long rest"); return
        }
        _ = e.drain()
        e.tick(seconds: 1, now: endedAt.addingTimeInterval(2))
        #expect(e.phase == .waiting(short)); #expect(e.remaining(.long) == 298)
        #expect(e.effects.isEmpty)
        e.tick(seconds: 297, now: endedAt.addingTimeInterval(299))
        #expect(e.phase == .waiting(short)); #expect(e.effects.isEmpty)
        e.tick(seconds: 1, now: endedAt.addingTimeInterval(300))
        #expect(e.reminder?.kind == .long)
        #expect(e.effects.count == 2); #expect(e.effects.first == .hide)
    }
    @Test func testLongCooldownPreservesDeferredShortUntilLongIsDue() {
        let e = engine(); e.tick(seconds: 3600, now: now); e.start(now: now)
        e.tick(seconds: 1, now: now.addingTimeInterval(1)); e.finish(now: now.addingTimeInterval(1))
        e.tick(seconds: 1, now: now.addingTimeInterval(2))
        guard let short = e.reminder, short.kind == .short else {
            Issue.record("Expected a short reminder"); return
        }
        e.postpone(now: now.addingTimeInterval(2)); _ = e.drain()
        e.tick(seconds: 1, now: now.addingTimeInterval(3))
        guard case .deferred(let deferred, let remaining) = e.phase else {
            Issue.record("Long cooldown must not cancel the deferred short reminder"); return
        }
        #expect(deferred.id == short.id); #expect(remaining == 119); #expect(e.effects.isEmpty)
        e.tick(seconds: 119, now: now.addingTimeInterval(122))
        #expect(e.reminder?.kind == .short); #expect(e.reminder?.id == short.id)
        #expect(e.remaining(.long) == 179)
        e.tick(seconds: 120, now: now.addingTimeInterval(242))
        e.postpone(now: now.addingTimeInterval(242)); _ = e.drain()
        e.tick(seconds: 58, now: now.addingTimeInterval(300))
        #expect(e.reminder?.id == short.id); #expect(e.remaining(.long) == 1)
        #expect(e.effects.isEmpty)
        e.tick(seconds: 1, now: now.addingTimeInterval(301))
        #expect(e.reminder?.kind == .long)
        #expect(e.effects.count == 2); #expect(e.effects.first == .hide)
    }
    @Test func testLongRestMeetingShortDurationDoesNotPresentShortAfterEarlyEnd() {
        let e = engine(); e.tick(seconds: 3600, now: now); e.start(now: now)
        e.tick(seconds: 20, now: now.addingTimeInterval(20)); e.finish(now: now.addingTimeInterval(20))
        _ = e.drain()
        e.tick(seconds: 1, now: now.addingTimeInterval(21))
        #expect(e.reminder == nil); #expect(e.remaining(.short) == 1199)
        #expect(e.remaining(.long) == 299); #expect(e.effects.isEmpty)
    }
    @Test func testShortEndsEarlyCountsDownUntilRetry() {
        let e = engine(.overlay); e.tick(seconds: 1200, now: now)
        e.tick(seconds: 5, now: now.addingTimeInterval(5)); e.finish(now: now.addingTimeInterval(5))
        #expect(e.shortElapsed == 1200); #expect(e.remaining(.short) == 120)
        e.tick(seconds: 119, now: now.addingTimeInterval(124))
        #expect(e.remaining(.short) == 1); #expect(e.reminder == nil)
        e.tick(seconds: 1, now: now.addingTimeInterval(125))
        #expect(e.remaining(.short) == 0); #expect(e.reminder?.kind == .short)
    }
    @Test func testNextKindUsesCooldownAndUsageIntervalAfterRestart() {
        var snapshot = Snapshot(); snapshot.savedAt = now
        snapshot.shortElapsed = 1140; snapshot.longElapsed = 3600; snapshot.longCooldown = 300
        let e = Engine(settings: Settings(), snapshot: snapshot, now: now)
        #expect(e.remaining(.short) == 60); #expect(e.remaining(.long) == 300)
        #expect(e.nextKind == .short)
        // Restart grace is consumed before the next tick can present a reminder.
        e.tick(seconds: 30, now: now.addingTimeInterval(30))
        e.tick(seconds: 30, now: now.addingTimeInterval(60))
        #expect(e.reminder?.kind == .short)
        #expect(e.remaining(.long) == 240)
    }
    @Test func testEarlyEndPrewarningWaitsUntilCooldownIsNearlyOver() {
        var settings = Settings(); settings.style = .overlay; settings.prewarning = 10
        let e = Engine(settings: settings)
        e.tick(seconds: 3600, now: now)
        e.tick(seconds: 30, now: now.addingTimeInterval(30)); e.finish(now: now.addingTimeInterval(30))
        _ = e.drain()
        e.tick(seconds: 1, now: now.addingTimeInterval(31))
        #expect(!e.effects.contains(.warning(.long)))
        e.tick(seconds: 289, now: now.addingTimeInterval(320))
        #expect(e.remaining(.long) == 10); #expect(e.effects.contains(.warning(.long)))
    }
    @Test func testPostponementKeepsIdentityAndLimit() {
        let e = engine(); e.tick(seconds: 1200, now: now)
        let id = e.reminder!.id
        e.postpone(now: now); e.tick(seconds: 120, now: now.addingTimeInterval(120))
        #expect(e.reminder?.id == id); #expect(e.reminder?.postponements == 1)
        e.postpone(now: now); e.tick(seconds: 120, now: now.addingTimeInterval(240)); e.postpone(now: now)
        #expect(e.reminder?.postponements == 2)
        guard case .waiting = e.phase else { Issue.record("Third postponement should be rejected"); return }
    }
    @Test func testPauseFreezesDeferredCountdownAndPreservesBudget() {
        let e = engine(); e.tick(seconds: 1200, now: now); e.postpone(now: now)
        e.tick(seconds: 20, now: now.addingTimeInterval(20))
        e.setPause(.indefinite, now: now); e.tick(seconds: 600, now: now.addingTimeInterval(600))
        guard case .deferred(let r, let remaining) = e.phase else { Issue.record("Postponement must survive pause"); return }
        #expect(remaining == 100); #expect(r.postponements == 1)
        e.setPause(nil, now: now); #expect(e.reminder?.id == r.id)
    }
    @Test func testNaturalLongRestCancelsPendingReminder() {
        let e = engine(); e.tick(seconds: 3600, now: now)
        e.beginAway(at: now); e.endAway(now: now.addingTimeInterval(360), minimumShort: 60)
        #expect(e.shortElapsed == 0); #expect(e.longElapsed == 0); #expect(e.reminder == nil)
        #expect(TodaySummary(records: e.records, now: now).completed == 0)
    }
    @Test func testShortLockPreservesTimersAndLongerLockResetsOnlyShort() {
        let e = engine(); e.tick(seconds: 1000, now: now)
        e.beginAway(at: now); e.endAway(now: now.addingTimeInterval(10), minimumShort: 20)
        #expect(e.shortElapsed == 1000)
        e.beginAway(at: now); e.endAway(now: now.addingTimeInterval(30), minimumShort: 20)
        #expect(e.shortElapsed == 0); #expect(e.longElapsed == 1000)
    }
    @Test func testRestThenSleepDoesNotDoubleCountCompletion() {
        let e = engine(.overlay); e.tick(seconds: 3600, now: now)
        e.tick(seconds: 30, now: now.addingTimeInterval(30)); e.beginAway(at: now.addingTimeInterval(30))
        e.endAway(now: now.addingTimeInterval(301), minimumShort: 20)
        #expect(e.longElapsed == 0)
        let summary = TodaySummary(records: e.records, now: now)
        #expect(summary.completed == 0); #expect(summary.rest == 30); #expect(summary.natural == 271)
    }
    @Test func testFullscreenDoesNotResumeManualPause() {
        let e = engine(); e.setPause(.indefinite, now: now); e.setSuppressed(true)
        e.tick(seconds: 600, now: now); e.setSuppressed(false); e.tick(seconds: 600, now: now)
        #expect(e.pause == .indefinite); #expect(e.shortElapsed == 0)
    }
    @Test func testFullscreenAccumulatesUsageWithoutBacklog() {
        let e = engine(); e.setSuppressed(true); e.tick(seconds: 7200, now: now)
        #expect(e.shortElapsed == 1200); #expect(e.longElapsed == 3600); #expect(e.reminder == nil)
        e.setSuppressed(false); e.tick(seconds: 30, now: now); e.tick(seconds: 1, now: now)
        #expect(e.reminder?.kind == .long)
        #expect(e.effects.filter { if case .show = $0 { return true }; return false }.count == 1)
    }
    @Test func testRestartDoesNotInferOfflineRest() {
        let e = engine(); e.tick(seconds: 1000, now: now)
        let restored = Engine(settings: e.settings, snapshot: e.snapshot(now: now), now: now.addingTimeInterval(600))
        #expect(restored.shortElapsed == 1000); #expect(restored.longElapsed == 1000)
    }
    @Test func testCrashedRestIsInterruptedNotCompleted() {
        let e = engine(.overlay); e.startNow(.long, now: now); e.tick(seconds: 30, now: now)
        let restored = Engine(settings: e.settings, snapshot: e.snapshot(now: now), now: now.addingTimeInterval(600))
        #expect(!(restored.isResting))
        #expect(restored.records.filter { $0.outcome == .completed }.count == 0)
        #expect(restored.records.filter { $0.outcome == .interrupted }.count == 1)
    }
    @Test func testOvernightScheduleUsesStartDay() {
        var s = Settings(); s.scheduleEnabled = true; s.weekdays = [2]; s.scheduleStart = 22 * 60; s.scheduleEnd = 2 * 60
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let monday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 23))!
        let tuesday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 1))!
        let late = calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 3))!
        #expect(s.isWorkingTime(monday, calendar: calendar)); #expect(s.isWorkingTime(tuesday, calendar: calendar))
        #expect(!(s.isWorkingTime(late, calendar: calendar)))
    }
    @Test func testUsageIsSplitAcrossMidnight() {
        let e = engine()
        let midnight = Calendar.current.startOfDay(for: now)
        e.tick(seconds: 20, now: midnight.addingTimeInterval(10))
        let usage = e.records.filter { $0.outcome == .usage }
        #expect(usage.count == 2); #expect(usage[0].seconds == 10); #expect(usage[1].seconds == 10)
        #expect(usage[0].day != usage[1].day)
    }
    @Test func testManualRestWorksOutsideSchedule() {
        var s = Settings(); s.scheduleEnabled = true; s.weekdays = []
        let e = Engine(settings: s); e.startNow(.short, now: now); e.tick(seconds: 20, now: now)
        #expect(TodaySummary(records: e.records, now: now).completed == 1)
    }
    @Test func testPersistenceRoundtripAndCorruptionPreservation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.json"), store = DataStore(url: url)
        var data = SavedData(); data.settings.language = "zh-Hans"
        try store.save(data); #expect(store.load().settings.language == "zh-Hans")
        try Data("broken".utf8).write(to: url)
        let corrupt = DataStore(url: url); _ = corrupt.load(); #expect(corrupt.loadError != nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix("state-damaged-") })
    }
    @Test func testLocalizationFallbackAndFormats() {
        L10n.language = "fr"; #expect(L10n.resolvedLanguage.lowercased() == "zh-hans")
        #expect(L10n.text("app.name") == AppIdentity.name)
        #expect(L10n.text("welcome.title") == "欢迎使用\(AppIdentity.name)")
        #expect(L10n.text("general.login_help").contains(AppIdentity.name))
        #expect(!L10n.text("welcome.menu_help").contains("{appName}"))
        #expect(L10n.text("menu.remaining", "护眼休息", "12:34") == "护眼休息还有 12:34")
        #expect(L10n.availableLanguages.contains { $0.lowercased() == "zh-hans" }); L10n.language = "system"
    }
    @Test func testLegacyStateAddsIdleTimeoutWithoutLosingData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("state.json")
        var saved = SavedData()
        saved.settings.shortInterval = 1800
        saved.settings.detectIdle = false
        saved.settings.onboardingComplete = true
        saved.snapshot.pause = .indefinite
        saved.records = [Record(date: now, kind: .short, outcome: .completed, seconds: 20)]
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as! [String: Any]
        var settings = json["settings"] as! [String: Any]
        settings.removeValue(forKey: "idleTimeout")
        json["settings"] = settings
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let store = DataStore(url: url), loaded = store.load()
        #expect(store.loadError == nil)
        #expect(loaded.settings.idleTimeout == 300)
        #expect(loaded.settings.shortInterval == 1800)
        #expect(!loaded.settings.detectIdle)
        #expect(loaded.settings.onboardingComplete)
        #expect(loaded.snapshot.pause == .indefinite)
        #expect(loaded.records.first?.id == saved.records.first?.id)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["state.json"])
    }
    @Test func testCustomIdleTimeoutSurvivesRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DataStore(url: directory.appendingPathComponent("state.json"))
        var saved = SavedData(); saved.settings.idleTimeout = 420
        try store.save(saved)
        #expect(DataStore(url: store.url).load().settings == saved.settings)
    }
    @Test(arguments: [0.0, 59, 3601, Double.infinity, Double.nan])
    func testInvalidIdleTimeoutIsRejected(_ timeout: Double) {
        var settings = Settings(); settings.idleTimeout = timeout
        #expect(settings.validationError != nil)
    }
}
