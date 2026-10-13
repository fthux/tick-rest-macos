import Foundation
import XCTest
import TickRestCore
@testable import TickRestApp

final class MenuBarCountdownTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func engine(remaining: Double) -> Engine {
        var settings = Settings(); settings.prewarning = 0
        let engine = Engine(settings: settings)
        engine.tick(seconds: settings.shortInterval - remaining, now: now)
        return engine
    }

    func testSmallSchedulerJitterStillDisplaysIntermediateSecond() {
        let engine = engine(remaining: 1097.005)
        let sample = MenuBarCountdown(engine: engine, uptime: 100)
        XCTAssertEqual(sample.text(at: 100), "18:18")
        XCTAssertEqual(sample.text(at: 100.2), "18:17")
        XCTAssertEqual(sample.text(at: 100.8), "18:17")
        engine.tick(seconds: 1.010, now: now.addingTimeInterval(1.010))
        let next = MenuBarCountdown(engine: engine, uptime: 101.010)
        XCTAssertEqual(next.text(at: 101.010), "18:16")
        XCTAssertEqual(next.text(at: 101.210), "18:16")
    }

    func testProjectionDoesNotAdvanceEngineStatisticsOrEffectsAndHonorsStallCap() {
        let engine = engine(remaining: 1097.005)
        let phase = engine.phase, elapsed = engine.shortElapsed
        let effects = engine.effects, records = engine.records
        let sample = MenuBarCountdown(engine: engine, uptime: 100)
        XCTAssertEqual(sample.text(at: 99), "18:18")
        XCTAssertEqual(sample.text(at: 103), "18:15")
        XCTAssertEqual(sample.text(at: 110), "18:13")
        XCTAssertEqual(engine.phase, phase)
        XCTAssertEqual(engine.shortElapsed, elapsed)
        XCTAssertEqual(engine.effects, effects)
        XCTAssertEqual(engine.records.map(\.id), records.map(\.id))
        XCTAssertEqual(engine.records.map(\.seconds), records.map(\.seconds))
        XCTAssertEqual(engine.records.map(\.date), records.map(\.date))
        // The next real tick catches up immediately instead of replaying missing digits.
        engine.tick(seconds: 5, now: now.addingTimeInterval(10))
        XCTAssertEqual(MenuBarCountdown(engine: engine, uptime: 110).text(at: 110), sample.text(at: 110))
    }

    func testPauseAndAwayFreezeAndResumeUsesNewAnchor() {
        let engine = engine(remaining: 1097.005)
        engine.setPause(.indefinite, now: now)
        let paused = MenuBarCountdown(engine: engine, uptime: 100)
        XCTAssertEqual(paused.text(at: 200), ReminderDisplay(engine: engine).menuBarText)
        engine.setPause(nil, now: now)
        let resumed = MenuBarCountdown(engine: engine, uptime: 200)
        XCTAssertEqual(resumed.text(at: 200), "18:18")
        XCTAssertEqual(resumed.text(at: 200.2), "18:17")
        engine.beginAway(at: now)
        let away = MenuBarCountdown(engine: engine, uptime: 201)
        XCTAssertEqual(away.text(at: 300), ReminderDisplay(engine: engine).menuBarText)
    }

    func testRestUsesItsOwnCountdownAndFreezesWhileAway() {
        let engine = engine(remaining: 1097.005)
        engine.startNow(.short, now: now)
        let target = engine.reminder!.target
        let resting = MenuBarCountdown(engine: engine, uptime: 100)
        XCTAssertEqual(resting.text(at: 101.2), L10n.clock(target - 1.2))
        engine.beginAway(at: now)
        let away = MenuBarCountdown(engine: engine, uptime: 101)
        XCTAssertEqual(away.text(at: 200), L10n.clock(target))
        engine.endAway(now: now.addingTimeInterval(target + 1), minimumShort: target)
        XCTAssertFalse(engine.isResting)
        let working = MenuBarCountdown(engine: engine, uptime: 200)
        XCTAssertEqual(working.text(at: 200), ReminderDisplay(engine: engine).menuBarText)
    }

    func testZeroWaitsForRealEngineTransitionAndManualWaitingDoesNotCountDown() {
        let engine = engine(remaining: 0.5)
        let sample = MenuBarCountdown(engine: engine, uptime: 100)
        XCTAssertEqual(sample.text(at: 101), "00:00")
        XCTAssertFalse(engine.isResting)
        engine.tick(seconds: 1, now: now.addingTimeInterval(1))
        XCTAssertTrue(engine.isResting)
        XCTAssertEqual(MenuBarCountdown(engine: engine, uptime: 101).text(at: 101), L10n.clock(engine.reminder!.target))

        var settings = Settings(); settings.breakStartMode = .manual; settings.prewarning = 0
        let manual = Engine(settings: settings)
        manual.tick(seconds: settings.shortInterval, now: now)
        let waiting = MenuBarCountdown(engine: manual, uptime: 100)
        XCTAssertEqual(waiting.text(at: 200), ReminderDisplay(engine: manual).menuBarText)
        manual.postpone(now: now)
        let deferred = MenuBarCountdown(engine: manual, uptime: 200)
        XCTAssertEqual(deferred.text(at: 300), ReminderDisplay(engine: manual).menuBarText)
    }

    func testCosmeticRefreshPreservesAnchorButNewRestRebases() {
        let engine = engine(remaining: 1097.005)
        let first = MenuBarCountdown(engine: engine, uptime: 100)
        var settings = engine.settings; settings.showStatusDot = false
        engine.updateSettings(settings)
        var cosmetic = MenuBarCountdown(engine: engine, uptime: 100.8)
        cosmetic.preserveAnchor(from: first)
        XCTAssertEqual(cosmetic.text(at: 101.01), "18:16")
        engine.startNow(.short, now: now)
        var rest = MenuBarCountdown(engine: engine, uptime: 101.01)
        rest.preserveAnchor(from: cosmetic)
        XCTAssertEqual(rest.text(at: 101.01), L10n.clock(engine.reminder!.target))
    }

    func testScheduleDisabledRemindersAndFullscreenRespectEngineState() {
        var settings = Settings(); settings.scheduleEnabled = true; settings.weekdays = []
        let outside = Engine(settings: settings); outside.tick(seconds: 0, now: now)
        XCTAssertEqual(MenuBarCountdown(engine: outside, uptime: 100).text(at: 200), ReminderDisplay(engine: outside).menuBarText)
        settings = Settings(); settings.shortEnabled = false; settings.longEnabled = false
        XCTAssertEqual(MenuBarCountdown(engine: Engine(settings: settings), uptime: 100).text(at: 200), "")
        let suppressed = engine(remaining: 1097.005); suppressed.setSuppressed(true)
        XCTAssertEqual(MenuBarCountdown(engine: suppressed, uptime: 100).text(at: 100.2), "18:17")
    }
}
