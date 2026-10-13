import Foundation
import Testing
@testable import TickRestCore

/// Isolated regressions and stress checks from the comprehensive audit.
@Suite(.serialized)
struct ComprehensiveAudit20261014Tests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test(arguments: [RestPlanID.tickrest, .eye202020, .fiftyTen, .pomodoro], [0.0, 1.0])
    func pausedRestSurvivesRestartThenPlanReplacement(_ plan: RestPlanID, _ elapsed: Double) throws {
        var settings = Settings(); settings.restPlan = .preset(plan); settings.prewarning = 0
        let original = Engine(settings: settings)
        original.startNow(.short, now: now)
        original.tick(seconds: elapsed, now: now.addingTimeInterval(elapsed))
        original.setPause(.indefinite, now: now)
        let reminder = try #require(original.reminder)
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(original.snapshot(now: now)))
        let restored = Engine(settings: settings, snapshot: snapshot, now: now)
        let replacement = RestPlan.preset(plan == .fiftyTen ? .eye202020 : .fiftyTen)
        restored.applyPlan(replacement, now: now)
        #expect(restored.settings.restPlan == settings.restPlan,
                "Restart must preserve a paused break's plan until that break settles")
        #expect(restored.reminder == reminder && restored.pendingPlan == replacement)
        #expect(restored.pause == .indefinite)
        restored.setPause(nil, now: now)
        restored.tick(seconds: 30, now: now.addingTimeInterval(30))
        restored.tick(seconds: 0, now: now.addingTimeInterval(30))
        #expect(restored.isResting && restored.reminder?.id == reminder.id)
        restored.tick(seconds: reminder.target - reminder.elapsed,
                      now: now.addingTimeInterval(30 + reminder.target - reminder.elapsed))
        #expect(restored.settings.restPlan == replacement && restored.pendingPlan == nil)
        #expect(restored.reminder == nil)
    }

    @Test func waitingReminderRemainsReplaceableAfterRestart() throws {
        var settings = Settings(); settings.restPlan = .preset(.eye202020)
        settings.prewarning = 0; settings.breakStartMode = .manual
        let original = Engine(settings: settings)
        original.tick(seconds: settings.shortInterval, now: now)
        original.setPause(.indefinite, now: now)
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(original.snapshot(now: now)))
        #expect(snapshot.pausedRestID == nil)
        let restored = Engine(settings: settings, snapshot: snapshot, now: now)
        restored.applyPlan(.preset(.fiftyTen), now: now)
        #expect(restored.settings.planID == .fiftyTen && restored.pendingPlan == nil && restored.reminder == nil)
    }

    @Test(arguments: [RestPlanID.tickrest, .eye202020, .fiftyTen, .pomodoro])
    func repeatedPartialAwaySegmentsAndPausesConserveMeasuredTime(_ plan: RestPlanID) throws {
        var settings = Settings(); settings.restPlan = .preset(plan); settings.prewarning = 0
        let engine = Engine(settings: settings); var time = now
        var usage = 0.0, natural = 0.0, rest = 0.0
        for _ in 0..<100 {
            time = time.addingTimeInterval(7); engine.tick(seconds: 7, now: time)
            usage += 7
            engine.startNow(.short, now: time)
            time = time.addingTimeInterval(3); engine.tick(seconds: 3, now: time); rest += 3
            engine.setPause(.indefinite, now: time)
            engine.beginAway(at: time)
            time = time.addingTimeInterval(2); engine.endAway(now: time, minimumShort: settings.shortDuration); natural += 2
            engine.skip(now: time); engine.setPause(nil, now: time)
        }
        let summary = TodaySummary(records: engine.records, now: time)
        #expect(abs(summary.usage - usage) < 0.001)
        #expect(abs(summary.rest - rest) < 0.001)
        #expect(abs(summary.natural - natural) < 0.001)
        #expect(abs(summary.usage + summary.rest + summary.natural - time.timeIntervalSince(now)) < 0.001)
        #expect(engine.records.filter { $0.outcome == .skipped }.count == 100)
    }

    @Test(arguments: [RestPlanID.tickrest, .eye202020, .fiftyTen, .pomodoro])
    func randomizedPublicActionsAlwaysProduceReloadableState(_ plan: RestPlanID) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = Settings(); settings.restPlan = .preset(plan); settings.prewarning = 0
        let engine = Engine(settings: settings); var time = now
        var seed: UInt64 = 0x20261014
        let store = DataStore(url: directory.appendingPathComponent("state.json"))
        var records: [Record] = []
        for index in 0..<5000 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            switch (seed >> 32) % 12 {
            case 0: engine.startNow(.short, now: time)
            case 1: engine.startNow(.long, now: time)
            case 2: engine.start(now: time)
            case 3: engine.postpone(now: time)
            case 4: engine.skip(now: time)
            case 5: engine.finish(now: time)
            case 6: engine.setPause(.indefinite, now: time)
            case 7: engine.setPause(nil, now: time)
            case 8: engine.beginAway(at: time)
            case 9: engine.endAway(now: time, minimumShort: engine.settings.shortDuration)
            case 10: engine.setSuppressed(!engine.suppressed)
            default: engine.restartFocus(group: seed & 1 == 0, now: time)
            }
            let delta = Double((seed >> 48) % 11) / 2
            time = time.addingTimeInterval(delta); engine.tick(seconds: delta, now: time)
            let (_, additions) = engine.drain()
            DataStore.append(additions, to: &records, now: time)
            #expect(additions.allSatisfy { $0.seconds.isFinite && $0.seconds >= 0 })
            if index % 50 == 0 {
                var saved = SavedData(); saved.settings = engine.settings
                saved.snapshot = engine.snapshot(now: time); saved.records = records
                try store.save(saved); let loaded = store.load()
                #expect(store.loadErrorKey == nil, "Valid public actions produced an unloadable snapshot at step \(index)")
                #expect(loaded.records.count == records.count)
            }
        }
    }

    @Test(arguments: [(540, 1080), (1320, 120), (0, 1), (1439, 0)])
    func schedulesMatchAnIndependentMinuteByMinuteWeekOracle(_ hours: (Int, Int)) throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let sunday = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 11)))
        var settings = Settings(); settings.scheduleEnabled = true
        settings.weekdays = [2, 4, 6]; settings.scheduleStart = hours.0; settings.scheduleEnd = hours.1
        for day in 0..<7 {
            for minute in 0..<1440 {
                let date = sunday.addingTimeInterval(Double(day * 86400 + minute * 60))
                let weekday = day + 1
                let previous = weekday == 1 ? 7 : weekday - 1
                let expected = hours.0 < hours.1
                    ? settings.weekdays.contains(weekday) && minute >= hours.0 && minute < hours.1
                    : (minute >= hours.0 && settings.weekdays.contains(weekday))
                        || (minute < hours.1 && settings.weekdays.contains(previous))
                #expect(settings.isWorkingTime(date, calendar: calendar) == expected)
            }
        }
    }
}
