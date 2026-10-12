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

}
