import Foundation
import Testing
@testable import TickRestCore

struct ManualPauseTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test(arguments: [RestPlanID.tickrest, .eye202020, .pomodoro], BreakStartMode.allCases)
    func resumeContinuesLastEightSecondsWithoutRepeatingWarning(_ plan: RestPlanID, _ mode: BreakStartMode) {
        var settings = Settings(); settings.restPlan = .preset(plan)
        settings.prewarning = 10; settings.breakStartMode = mode
        let engine = Engine(settings: settings)
        engine.tick(seconds: settings.shortInterval - 8, now: now)
        #expect(engine.drain().0 == [.warning(.short)])

        engine.setPause(.indefinite, now: now)
        #expect(engine.drain().0 == [.hide])
        engine.tick(seconds: 3, now: now.addingTimeInterval(3))
        #expect(engine.remaining(.short) == 8)
        #expect(engine.drain().1.isEmpty)
        engine.setPause(nil, now: now.addingTimeInterval(3))
        _ = engine.drain()
        #expect(engine.graceRemaining == 0)

        for second in 1...8 {
            engine.tick(seconds: 1, now: now.addingTimeInterval(Double(3 + second)))
            #expect(!engine.effects.contains(.warning(.short)))
            if second < 8 { #expect(engine.reminder == nil) }
        }
        #expect(engine.remaining(.short) == 0)
        #expect(engine.reminder?.kind == .short)
        #expect(engine.isResting == (mode == .automatic))
        #expect(engine.effects.filter { if case .show = $0 { return true }; return false }.count == 1)

        _ = engine.drain()
        if mode == .manual { engine.start(now: now.addingTimeInterval(11)) }
        engine.tick(seconds: settings.shortDuration, now: now.addingTimeInterval(11 + settings.shortDuration))
        _ = engine.drain()
        engine.tick(seconds: settings.shortInterval - 10, now: now.addingTimeInterval(1_000 + settings.shortInterval))
        #expect(engine.effects == [.warning(.short)], "The next cycle must still send its own prewarning")
    }

    @Test(arguments: [false, true])
    func repeatedPausesDoNotExtendCountdownOrCreateWarnings(_ timed: Bool) {
        var settings = Settings(); settings.prewarning = 0
        let engine = Engine(settings: settings)
        engine.tick(seconds: settings.shortInterval - 8, now: now)
        _ = engine.drain()
        var time = now
        for _ in 0..<4 {
            engine.setPause(timed ? .until(time.addingTimeInterval(900)) : .indefinite, now: time)
            time = time.addingTimeInterval(3)
            engine.tick(seconds: 3, now: time)
            engine.setPause(nil, now: time)
            time = time.addingTimeInterval(2)
            engine.tick(seconds: 2, now: time)
        }
        #expect(engine.remaining(.short) == 0 && engine.isResting)
        #expect(engine.effects.filter { if case .show = $0 { return true }; return false }.count == 1)
        #expect(!engine.effects.contains(.warning(.short)))
    }

    @Test func pausePreservesExistingRecoveryGraceAndWarningIdentity() {
        var snapshot = Snapshot(); snapshot.savedAt = now
        snapshot.shortElapsed = Settings().shortInterval
        let engine = Engine(settings: Settings(), snapshot: snapshot, now: now)
        engine.tick(seconds: 20, now: now.addingTimeInterval(20))
        #expect(engine.graceRemaining == 10)
        #expect(engine.effects.contains(.warning(.short)))
        _ = engine.drain()
        engine.setPause(.indefinite, now: now.addingTimeInterval(20))
        engine.tick(seconds: 3, now: now.addingTimeInterval(23))
        engine.setPause(nil, now: now.addingTimeInterval(23))
        #expect(engine.graceRemaining == 10)
        _ = engine.drain()
        engine.tick(seconds: 1, now: now.addingTimeInterval(24))
        #expect(engine.graceRemaining == 9 && engine.effects.isEmpty)
    }

    @Test(arguments: [false, true])
    func resumeKeepsOtherReminderBlocks(_ away: Bool) {
        let engine = Engine(settings: Settings())
        engine.tick(seconds: engine.settings.shortInterval - 8, now: now)
        engine.setPause(.indefinite, now: now)
        if away { engine.beginAway(at: now) } else { engine.setSuppressed(true) }
        engine.setPause(nil, now: now.addingTimeInterval(3))
        _ = engine.drain()
        engine.tick(seconds: 8, now: now.addingTimeInterval(11))
        #expect(engine.reminder == nil && engine.effects.isEmpty)
        #expect(away ? engine.away : engine.suppressed)
        #expect(engine.remaining(.short) == (away ? 8 : 0))
    }

    @Test(arguments: BreakStartMode.allCases)
    func pauseKeepsAnAlreadyPresentedReminder(_ mode: BreakStartMode) throws {
        var settings = Settings(); settings.breakStartMode = mode
        let engine = Engine(settings: settings)
        engine.tick(seconds: settings.shortInterval, now: now)
        if mode == .automatic { engine.tick(seconds: 3, now: now.addingTimeInterval(3)) }
        let original = try #require(engine.reminder)
        engine.setPause(.indefinite, now: now.addingTimeInterval(3))
        engine.tick(seconds: 5, now: now.addingTimeInterval(8))
        engine.setPause(nil, now: now.addingTimeInterval(8))
        _ = engine.drain()
        engine.tick(seconds: 1, now: now.addingTimeInterval(9))
        #expect(engine.reminder?.id == original.id && engine.reminder?.elapsed == original.elapsed)
        #expect(engine.effects == [.show(original)])
    }
}
