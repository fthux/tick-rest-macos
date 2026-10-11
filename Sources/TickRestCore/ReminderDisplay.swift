import Foundation

/// Shared menu text derived from the scheduler without changing its timing or effects.
public struct ReminderDisplay {
    private let engine: Engine
    public init(engine: Engine) { self.engine = engine }

    public var menuBarText: String {
        if let r = engine.reminder, engine.isResting { return L10n.clock(r.target - r.elapsed) }
        if engine.pause != nil || engine.away || engine.outsideSchedule { return L10n.text("menu.paused_short") }
        if case .waiting(let r) = engine.phase { return dueTitle(r.kind) }
        if case .deferred = engine.phase { return L10n.text("menu.later_short") }
        guard let kind = engine.nextKind else { return "" }
        if engine.remaining(kind) > 0 { return L10n.clock(engine.remaining(kind)) }
        if engine.suppressed || engine.graceRemaining > 0 { return L10n.text("menu.later_short") }
        return dueTitle(kind)
    }

    public var stateText: String {
        if let pause = engine.pause {
            switch pause {
            case .until(let date): return L10n.text("state.pause_until", L10n.time(date))
            case .indefinite: return L10n.text("state.paused")
            }
        }
        if engine.away { return L10n.text("state.away") }
        if engine.outsideSchedule { return L10n.text("state.outside") }
        if engine.suppressed { return L10n.text("state.fullscreen") }
        switch engine.phase {
        case .resting(let r): return L10n.text("state.resting", r.title, L10n.clock(r.target - r.elapsed))
        case .waiting(let r): return L10n.text("state.waiting", r.title)
        case .deferred(let r, let seconds):
            if seconds > 0 { return L10n.text("state.deferred", r.title, L10n.clock(seconds)) }
            return dueText(r.kind)
        default:
            if let kind = engine.nextKind, engine.remaining(kind) == 0 { return dueText(kind) }
            if engine.settings.timingModel == .rounds { return L10n.text("plan.focus_state", engine.focusRound, engine.settings.rounds) }
            return L10n.text("state.running")
        }
    }

    public var menuStateText: String {
        if engine.pause != nil || engine.away || engine.outsideSchedule || engine.suppressed || engine.isResting { return stateText }
        if case .waiting = engine.phase { return L10n.text("menu.waiting") }
        if case .deferred(_, let seconds) = engine.phase {
            return laterText(max(seconds, engine.graceRemaining))
        }
        if let kind = engine.nextKind, engine.remaining(kind) == 0 {
            return engine.graceRemaining > 0 ? laterText(engine.graceRemaining) : L10n.text("menu.due_state")
        }
        return stateText
    }

    public func countdownText(for kind: BreakKind) -> String {
        if case .deferred(let r, let seconds) = engine.phase, r.kind == kind {
            if seconds > 0 { return L10n.text("state.deferred", engine.settings.breakTitle(kind), L10n.clock(seconds)) }
            return L10n.text("menu.due", engine.settings.breakTitle(kind))
        }
        if case .waiting(let r) = engine.phase, r.kind == kind { return L10n.text("menu.due", engine.settings.breakTitle(kind)) }
        let seconds = engine.remaining(kind)
        if engine.settings.timingModel == .rounds && engine.roundRestKind == nil {
            return L10n.text("plan.focus_remaining", engine.focusRound, engine.settings.rounds, L10n.clock(seconds))
        }
        return seconds > 0 ? L10n.text("menu.remaining", engine.settings.breakTitle(kind), L10n.clock(seconds)) : L10n.text("menu.due", engine.settings.breakTitle(kind))
    }

    private func laterText(_ seconds: Double) -> String {
        seconds > 0 ? L10n.text("menu.later_countdown", L10n.clock(seconds)) : L10n.text("menu.later_short")
    }
    private func dueTitle(_ kind: BreakKind) -> String {
        engine.settings.timingModel == .dual ? L10n.text(kind == .short ? "menu.due_short" : "menu.due_long") : L10n.text("menu.due", engine.settings.breakTitle(kind))
    }
    private func dueText(_ kind: BreakKind) -> String {
        if engine.pause == nil && !engine.away && !engine.outsideSchedule {
            if engine.suppressed { return L10n.text("state.due_later", engine.settings.breakTitle(kind)) }
            if engine.graceRemaining > 0 { return L10n.text("state.due_grace", engine.settings.breakTitle(kind), L10n.clock(engine.graceRemaining)) }
        }
        return L10n.text("menu.due", engine.settings.breakTitle(kind))
    }
}
