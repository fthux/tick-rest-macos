import Foundation
import Testing
@testable import TickRestCore

@Suite(.serialized)
struct ExtendedFunctionalAuditTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func settings(_ id: RestPlanID) -> Settings {
        var value = Settings(); value.restPlan = .preset(id); value.prewarning = 0
        return value
    }
    private func step(_ engine: Engine, _ seconds: Double, _ time: inout Date) {
        time = time.addingTimeInterval(seconds); engine.tick(seconds: seconds, now: time)
    }

    @Test(arguments: [RestPlanID.tickrest, .eye202020, .fiftyTen, .pomodoro], BreakStartMode.allCases)
    func repeatedCyclesConserveMeasuredTimeAndProduceUniqueCompletions(_ id: RestPlanID, _ mode: BreakStartMode) throws {
        var s = settings(id); s.breakStartMode = mode
        let engine = Engine(settings: s); var time = now
        var expectedUsage = 0.0; var expectedRest = 0.0
        var ids: Set<UUID> = []
        for _ in 0..<12 {
            let kind = try #require(engine.nextKind)
            let work = engine.remaining(kind)
            step(engine, work, &time); expectedUsage += work
            let reminder = try #require(engine.reminder)
            #expect(ids.insert(reminder.id).inserted)
            if mode == .manual {
                step(engine, 7, &time); expectedUsage += 7
                #expect(engine.reminder?.elapsed == 0)
                engine.start(now: time)
            }
            // Verify partial ticks as well as exact completion boundaries.
            step(engine, reminder.target / 3, &time)
            step(engine, reminder.target / 3, &time)
            step(engine, reminder.target - reminder.target / 3 * 2, &time)
            expectedRest += reminder.target
            #expect(engine.reminder == nil)
        }
        let usage = engine.records.filter { $0.outcome == .usage && $0.reminderID == nil }.map(\.seconds).reduce(0, +)
        let rest = engine.records.filter { $0.outcome == .usage && $0.reminderID != nil }.map(\.seconds).reduce(0, +)
        #expect(abs(usage - expectedUsage) < 0.0001)
        #expect(abs(rest - expectedRest) < 0.0001)
        let completed = engine.records.filter { $0.outcome == .completed }
        #expect(completed.count == 12 && Set(completed.compactMap(\.reminderID)) == ids)
        #expect(engine.records.filter { $0.outcome == .focusCompleted }.count == (id == .pomodoro ? 12 : 0))
    }

    @Test(arguments: [RestPlanID.tickrest, .eye202020, .fiftyTen, .pomodoro])
    func duplicateAwayAndReturnEventsDoNotDuplicateStatistics(_ id: RestPlanID) throws {
        let s = settings(id); let engine = Engine(settings: s); var time = now
        engine.startNow(.short, now: time); step(engine, 3, &time)
        let reminder = try #require(engine.reminder)
        engine.beginAway(at: time); engine.beginAway(at: time.addingTimeInterval(1))
        step(engine, 10, &time)
        #expect(engine.reminder?.elapsed == 3)
        engine.endAway(now: time, minimumShort: s.shortDuration)
        engine.endAway(now: time.addingTimeInterval(1), minimumShort: s.shortDuration)
        #expect(engine.records.filter { $0.outcome == .interrupted && $0.reminderID == reminder.id }.count == 1)
        #expect(engine.records.filter { $0.outcome == .natural }.map(\.seconds).reduce(0, +) == 10)
        #expect(engine.records.filter { $0.outcome == .usage && $0.reminderID != nil }.map(\.seconds).reduce(0, +) == 3)
    }

    @Test(arguments: ["shortInterval", "shortDuration", "longInterval", "longDuration", "prewarning", "idleTimeout", "shortPostpone", "longPostpone", "singlePostpone"],
          [Double.nan, Double.infinity, -Double.infinity])
    func nonFiniteSettingsCannotReachTheScheduler(_ field: String, _ number: Double) {
        var s = Settings()
        switch field {
        case "shortInterval": s.shortInterval = number
        case "shortDuration": s.shortDuration = number
        case "longInterval": s.longInterval = number
        case "longDuration": s.longDuration = number
        case "prewarning": s.prewarning = number
        case "idleTimeout": s.idleTimeout = number
        case "shortPostpone": s.shortPostpone = number
        case "longPostpone": s.longPostpone = number
        default: s.singlePostpone = number
        }
        #expect(s.validationErrorKey != nil)
    }

    @Test(arguments: [RestPlanID.tickrest, .eye202020, .fiftyTen, .pomodoro])
    func allApplicationPreferencesSurviveApplyingANewRoutine(_ destination: RestPlanID) {
        var s = Settings(); s.language = "ja"; s.theme = .dark
        s.style = .overlay; s.displayScope = .current; s.gentleReminderSize = .mini
        s.sound = true; s.reminderSound = .hero; s.detectIdle = false; s.idleTimeout = 60
        s.avoidFullscreen = false; s.scheduleEnabled = true; s.weekdays = [1, 7]
        s.scheduleStart = 60; s.scheduleEnd = 90; s.showCountdown = false; s.showStatusDot = false
        s.overlayBackgroundColor = SRGBColor(red: 0.6, green: 0.5, blue: 0.4)
        let engine = Engine(settings: s)
        engine.applyPlan(.preset(destination), now: now)
        var expected = s; expected.restPlan = .preset(destination)
        #expect(engine.settings == expected)
        #expect(engine.records.filter { $0.outcome == .planChanged }.count == 1)
    }

    @Test(arguments: ["warning", "waiting", "resting", "deferred"])
    func scheduledSessionEndingClosesEveryReminderState(_ state: String) {
        var s = Settings(); s.scheduleEnabled = true; s.weekdays = [2]
        s.breakStartMode = .manual
        var time = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 17, minute: 59, second: 40))!
        let engine = Engine(settings: s); engine.tick(seconds: 0, now: time)
        if state == "warning" { engine.tick(seconds: s.shortInterval - 10, now: time) }
        else {
            engine.tick(seconds: s.shortInterval, now: time)
            if state == "resting" { engine.start(now: time) }
            if state == "deferred" { engine.postpone(now: time) }
        }
        _ = engine.drain(); step(engine, 20, &time)
        #expect(engine.outsideSchedule && engine.reminder == nil && engine.effects.contains(.hide))
        #expect(engine.records.filter { $0.outcome == .interrupted }.count == (state == "resting" ? 1 : 0))
        #expect(engine.records.filter { $0.outcome == .usage }.isEmpty)
    }

    @Test func suppressionMustHideAnAlreadyVisiblePrewarning() {
        let engine = Engine(settings: Settings()); var time = now
        step(engine, 1190, &time)
        #expect(engine.effects.contains(.warning(.short)))
        _ = engine.drain(); engine.setSuppressed(true)
        #expect(engine.effects.contains(.hide), "AUDIT-07: fullscreen suppression must remove an earlier warning")
    }

    @Test(arguments: [false, true])
    func suppressionHidesGraceWarningsWithoutCancellingRunningBreaks(_ resting: Bool) {
        var s = Settings(); s.shortInterval = 60
        let engine = Engine(settings: s); var time = now
        if resting { engine.startNow(.short, now: time) }
        else {
            step(engine, 60, &time); engine.skip(now: time)
            engine.setSuppressed(true); engine.setSuppressed(false)
            step(engine, 60, &time)
            #expect(engine.effects.contains(.warning(.short)))
        }
        _ = engine.drain(); let reminder = engine.reminder
        engine.setSuppressed(true)
        #expect(engine.effects.contains(.hide) == !resting)
        #expect(engine.reminder == reminder && engine.isResting == resting)
    }

    @Test(arguments: [false, true])
    func timedPauseExpiresEvenWhileAwayWithoutChargingSuspendedTime(_ rest: Bool) {
        let engine = Engine(settings: settings(.eye202020)); var time = now
        if rest { engine.startNow(.short, now: time); step(engine, 3, &time) }
        else { step(engine, 100, &time) }
        engine.setPause(.until(time.addingTimeInterval(10)), now: time)
        engine.beginAway(at: time); step(engine, 15, &time)
        #expect(engine.pause == nil && engine.away)
        #expect(engine.shortElapsed == (rest ? 0 : 100))
        engine.endAway(now: time, minimumShort: 20)
        #expect(!engine.away)
        #expect(engine.records.filter { $0.outcome == .natural }.map(\.seconds).reduce(0, +) == 15)
    }

    @Test(arguments: ["negative-seconds", "impossible-day", "duplicate-id"])
    func damagedRecordDataDoesNotBecomeNegativeOrDuplicateStatistics(_ corruption: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DataStore(url: directory.appendingPathComponent("state.json"))
        var saved = SavedData()
        var record = Record(date: now, kind: nil, outcome: .usage, seconds: 5)
        if corruption == "negative-seconds" { record.seconds = -5 }
        if corruption == "impossible-day" { record.day = "2026-99-99" }
        saved.records = corruption == "duplicate-id" ? [record, record] : [record]
        try store.save(saved); let original = try Data(contentsOf: store.url)
        let loaded = store.load()
        #expect(store.loadErrorKey != nil, "AUDIT-05 extension: syntactically valid damaged records need validation")
        #expect(loaded.records.isEmpty)
        let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("state-damaged-") }
        #expect(backups.count == 1)
        if let file = backups.first { #expect(try Data(contentsOf: file) == original) }
    }

    @Test func olderRecordsArePrunedButTheExactRetentionBoundaryRemains() {
        let cutoff = now.addingTimeInterval(-DataStore.recordRetention)
        let expired = Record(date: cutoff.addingTimeInterval(-0.001), kind: nil, outcome: .usage, seconds: 8)
        let retained = Record(date: cutoff, kind: nil, outcome: .usage, seconds: 9)
        var records = [expired, retained]
        DataStore.append([], to: &records, now: now)
        #expect(records.map(\.id) == [retained.id])
    }

    @Test(arguments: ["Asia/Shanghai", "America/Los_Angeles", "Europe/Berlin"])
    func statisticsCustomDatesClampAndRollForwardAcrossTimeZones(_ zone: String) throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = try #require(TimeZone(identifier: zone))
        let today = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12)))
        var selection = StatisticsSelection(now: today)
        selection.select(.last30, now: today, calendar: calendar)
        let range = selection.range(now: today, calendar: calendar)
        #expect(range.startDay == "2026-10-03" && range.endDay == "2026-11-01")
        selection.select(.custom, now: today, calendar: calendar)
        let tomorrow = try #require(calendar.date(byAdding: .day, value: 1, to: today))
        #expect(selection.range(now: tomorrow, calendar: calendar) == range)
        selection.setCustomEnd(today.addingTimeInterval(-200 * 86400), now: today, calendar: calendar)
        let available = StatisticsDateRange.availableDates(now: today, calendar: calendar)
        #expect(selection.range(now: today, calendar: calendar).start == available.lowerBound)
        #expect(selection.range(now: today, calendar: calendar).end == available.lowerBound)
    }

    @Test func deterministicMixedActionsKeepSnapshotAndDurationsConsistent() throws {
        // Reproducible event sequence including all three timing models. Each
        // drained duration is compared to accepted work/rest time, independent
        // of the engine's own remaining-time calculations.
        let engine = Engine(settings: settings(.tickrest)); var time = now
        var seed: UInt64 = 0x20261012
        for index in 0..<1500 {
            seed = seed &* 6364136223846793005 &+ 1
            switch Int((seed >> 32) % 12) {
            case 0: engine.startNow(.short, now: time)
            case 1: engine.startNow(.long, now: time)
            case 2: engine.start(now: time)
            case 3: engine.postpone(now: time)
            case 4: engine.skip(now: time)
            case 5: engine.finish(now: time)
            case 6: engine.setPause(.indefinite, now: time)
            case 7: engine.setPause(nil, now: time)
            case 8:
                engine.beginAway(at: time); time = time.addingTimeInterval(3)
                engine.endAway(now: time, minimumShort: engine.settings.shortDuration)
            case 9: engine.setSuppressed(index % 2 == 0)
            case 10: engine.applyPlan(.preset([RestPlanID.tickrest, .eye202020, .fiftyTen, .pomodoro][index % 4]), now: time)
            default:
                let seconds = Double(seed % 17 + 1)
                let before = engine.snapshot(now: time)
                let charged = engine.pause == nil && !engine.away
                let resting = engine.isResting
                step(engine, seconds, &time)
                let tick = engine.drain().1.filter { $0.outcome == .usage }
                // Drain earlier actions before the next tick, so these are only
                // this tick's newly measured duration records.
                let expected = charged ? (resting ? min(seconds, (before.activeReminder?.target ?? 0) - (before.activeReminder?.elapsed ?? 0)) : seconds) : 0
                #expect(abs(tick.map(\.seconds).reduce(0, +) - expected) < 0.001)
            }
            let snapshot = engine.snapshot(now: time)
            #expect(snapshot.shortElapsed >= 0 && snapshot.longElapsed >= 0)
            #expect(snapshot.shortCooldown >= 0 && snapshot.longCooldown >= 0)
            if let r = engine.reminder {
                #expect(r.elapsed >= 0 && r.elapsed <= r.target)
                #expect(r.postponements >= 0 && r.postponements <= engine.settings.postponeLimit)
            }
            _ = engine.drain()
            _ = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(snapshot))
        }
    }
}
