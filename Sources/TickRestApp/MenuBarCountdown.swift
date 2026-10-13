import Foundation
import TickRestCore

/// A read-only sample for the lightweight menu timer; never advances the engine.
struct MenuBarCountdown {
    private enum Source: Equatable {
        case focus(BreakKind, RestPlan)
        case rest(UUID)
        case state
    }

    private let source: Source
    private let seconds: Double?
    private let advancing: Bool
    private let stateText: String
    private var uptime: TimeInterval

    init(engine: Engine, uptime: TimeInterval) {
        let display = ReminderDisplay(engine: engine)
        stateText = display.menuBarText
        self.uptime = uptime
        if let reminder = engine.reminder, engine.isResting {
            source = .rest(reminder.id)
            seconds = max(0, reminder.target - reminder.elapsed)
            advancing = engine.pause == nil && !engine.away
        } else if engine.pause == nil, !engine.away, !engine.outsideSchedule,
                  let kind = engine.nextKind, engine.remaining(kind) > 0,
                  !Self.hasPendingReminder(engine) {
            source = .focus(kind, engine.settings.restPlan)
            seconds = engine.remaining(kind)
            advancing = true
        } else {
            source = .state; seconds = nil; advancing = false
        }
    }

    private static func hasPendingReminder(_ engine: Engine) -> Bool {
        switch engine.phase {
        case .waiting, .deferred: return true
        default: return false
        }
    }

    mutating func preserveAnchor(from previous: Self) {
        // Cosmetic settings, language changes and record drains do not restart time.
        if source == previous.source, seconds == previous.seconds, advancing == previous.advancing {
            uptime = previous.uptime
        }
    }

    func text(at currentUptime: TimeInterval) -> String {
        guard let seconds else { return stateText }
        // Match AppController's five-second cap after a suspended event loop.
        let elapsed = advancing ? min(5, max(0, currentUptime - uptime)) : 0
        // At zero, wait for the engine to choose the next state or emit effects.
        return L10n.clock(max(0, seconds - elapsed))
    }
}
