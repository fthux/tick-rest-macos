import Foundation
import Testing
@testable import TickRestCore

struct RecoveryWarningTests {
    @Test(arguments: [10.0, 30.0, 60.0], ["fullscreen", "timed-pause", "restart", "away", "settings"])
    func recoveryPreservesTheAnnouncedWarningTime(_ warning: Double, _ route: String) throws {
        var settings = Settings(); settings.prewarning = warning
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var engine = Engine(settings: settings)
        engine.setSuppressed(true)
        engine.tick(seconds: settings.shortInterval, now: now)
        engine.setSuppressed(false)
        switch route {
        case "timed-pause": engine.setPause(.until(now), now: now)
        case "restart": engine = Engine(settings: settings, snapshot: engine.snapshot(now: now), now: now)
        case "away":
            engine.beginAway(at: now.addingTimeInterval(-1))
            engine.endAway(now: now, minimumShort: 60)
        case "settings":
            var changed = settings; changed.detectIdle.toggle(); engine.updateSettings(changed)
        default: break
        }
        _ = engine.drain()
        var warningAt: Int?, showAt: Int?, warnings = 0
        for second in 1...100 {
            engine.tick(seconds: 1, now: now.addingTimeInterval(Double(second)))
            for effect in engine.drain().0 {
                if case .warning = effect { warningAt = second; warnings += 1 }
                if case .show = effect { showAt = second }
            }
            if showAt != nil { break }
        }
        let lead = try #require(showAt) - #require(warningAt)
        #expect(warnings == 1)
        #expect(Double(lead) >= warning && Double(lead) <= warning + 1)
    }

    @Test func disabledPrewarningStillUsesThirtySecondRecovery() {
        var settings = Settings(); settings.prewarning = 0
        let engine = Engine(settings: settings)
        engine.setSuppressed(true); engine.setSuppressed(false)
        #expect(engine.graceRemaining == 30)
        engine.setPause(.indefinite, now: Date()); engine.setPause(nil, now: Date())
        #expect(engine.graceRemaining == 30)
    }
}
