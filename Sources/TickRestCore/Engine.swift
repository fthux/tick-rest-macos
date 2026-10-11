import Foundation

public enum EngineEffect: Equatable {
    case warning(BreakKind), show(Reminder), hide, completed(BreakKind)
}

/// Deterministic scheduler: the adapter supplies elapsed active seconds and wall time.
/// No system APIs or UI objects are used here, so sleep/idle transitions are testable.
public final class Engine {
    public private(set) var settings: Settings
    public private(set) var phase: Phase = .working
    public private(set) var shortElapsed: Double = 0
    public private(set) var longElapsed: Double = 0
    public private(set) var pause: PauseMode?
    public private(set) var records: [Record] = []
    public private(set) var effects: [EngineEffect] = []
    public private(set) var away = false
    public private(set) var suppressed = false
    public private(set) var outsideSchedule = false
    public private(set) var completedRounds = 0
    public private(set) var roundRestKind: BreakKind?
    public private(set) var pendingPlan: RestPlan?
    private var grace: Double = 0
    private var shortCooldown: Double = 0
    private var longCooldown: Double = 0
    private var priorWorkingTime: Bool?
    private var awayStarted: Date?
    private var interruptedReminder: Reminder?
    private var warnedKind: BreakKind?
    private var lastIdea: [BreakKind: Int] = [:]
    public init(settings: Settings, snapshot: Snapshot? = nil, now: Date = Date()) {
        self.settings = settings
        if let saved = snapshot {
            let sameSession = !settings.scheduleEnabled || Self.sessionStart(settings, saved.savedAt) == Self.sessionStart(settings, now)
            shortElapsed = sameSession ? saved.shortElapsed : 0
            longElapsed = sameSession ? saved.longElapsed : 0
            shortCooldown = sameSession ? saved.shortCooldown : 0
            longCooldown = sameSession ? saved.longCooldown : 0
            completedRounds = sameSession ? min(settings.rounds, max(0, saved.completedRounds ?? 0)) : 0
            roundRestKind = sameSession ? saved.roundRestKind : nil
            pendingPlan = saved.pendingPlan
            pause = saved.pause
            if let active = saved.activeReminder {
                appendRecord(Record(date: now, kind: active.kind, outcome: .interrupted, seconds: active.elapsed, reminderID: active.id))
                if active.elapsed >= settings.shortDuration { shortElapsed = 0 }
            }
            if sameSession, let deferred = saved.deferredReminder, let remaining = saved.deferredRemaining {
                phase = .deferred(deferred, remaining)
            }
            if let pending = pendingPlan { installPlan(pending, now: now) }
            grace = 30
        }
        if case .until(let end) = pause, end <= now { pause = nil }
    }
    private static func sessionStart(_ settings: Settings, _ date: Date) -> Date? {
        guard settings.isWorkingTime(date) else { return nil }
        let calendar = Calendar.current
        var startDay = calendar.startOfDay(for: date)
        let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        if settings.scheduleStart > settings.scheduleEnd && minute < settings.scheduleEnd {
            startDay = calendar.date(byAdding: .day, value: -1, to: startDay) ?? startDay
        }
        return calendar.date(byAdding: .minute, value: settings.scheduleStart, to: startDay)
    }
    public func updateSettings(_ value: Settings) {
        // Presentation changes preserve deadlines, grace and warning identity.
        var appearanceOnly = settings
        appearanceOnly.theme = value.theme
        appearanceOnly.language = value.language
        appearanceOnly.style = value.style
        appearanceOnly.gentleReminderSize = value.gentleReminderSize
        appearanceOnly.displayScope = value.displayScope
        appearanceOnly.sound = value.sound
        appearanceOnly.reminderSound = value.reminderSound
        appearanceOnly.showCountdown = value.showCountdown
        appearanceOnly.onboardingComplete = value.onboardingComplete
        appearanceOnly.showStatusDot = value.showStatusDot
        appearanceOnly.statusDotPalette = value.statusDotPalette
        appearanceOnly.overlayBackgroundColor = value.overlayBackgroundColor
        if appearanceOnly == value { settings = value; return }
        if let pending = pendingPlan {
            var future = value; future.restPlan = pending
            guard future.validationErrorKey == nil else { return }
        }
        if !settings.shortEnabled && value.shortEnabled { shortElapsed = 0 }
        if !settings.longEnabled && value.longEnabled { longElapsed = 0 }
        let active = reminder
        settings = value
        if let active, !value.enabled(active.kind) { phase = .working; effects.append(.hide) }
        grace = 30; warnedKind = nil
    }
    public func applyPlan(_ plan: RestPlan, now: Date) {
        var candidate = settings; candidate.restPlan = plan
        guard candidate.validationErrorKey == nil else { return }
        if isResting { pendingPlan = plan }
        else { installPlan(plan, now: now) }
    }
    public func cancelPendingPlan() { pendingPlan = nil }
    private func installPlan(_ plan: RestPlan, now: Date) {
        appendRecord(Record(date: now, kind: nil, outcome: .planChanged))
        settings.restPlan = plan; pendingPlan = nil
        shortElapsed = 0; longElapsed = 0; shortCooldown = 0; longCooldown = 0
        completedRounds = 0; roundRestKind = nil; interruptedReminder = nil
        // The new routine starts after the switch, even when the user is away.
        if away { awayStarted = now }
        phase = .working; warnedKind = nil; grace = 0; effects.append(.hide)
    }
    private func applyPending(now: Date) {
        if let pending = pendingPlan { installPlan(pending, now: now) }
    }
    public func restartFocus(group: Bool, now: Date) {
        guard settings.timingModel == .rounds else { return }
        if let r = reminder { record(r, .interrupted, now, includeDuration: false) }
        appendRecord(Record(date: now, kind: nil, outcome: .restarted))
        if group { completedRounds = 0 }
        // A completed group's next focus belongs to a fresh group.
        if completedRounds >= settings.rounds { completedRounds = 0 }
        shortElapsed = 0; longElapsed = 0; shortCooldown = 0; longCooldown = 0
        roundRestKind = nil; phase = .working; warnedKind = nil; grace = 0
        interruptedReminder = nil; if away { awayStarted = now }
        effects.append(.hide); applyPending(now: now)
    }
    public var focusRound: Int { max(1, min(settings.rounds, completedRounds + (roundRestKind == nil ? 1 : 0))) }
    public var displayKinds: [BreakKind] {
        if settings.timingModel == .rounds { return [roundRestKind ?? (completedRounds + 1 >= settings.rounds ? .long : .short)] }
        return BreakKind.allCases.filter(settings.enabled)
    }
    public var reminder: Reminder? {
        switch phase {
        case .waiting(let reminder), .resting(let reminder), .deferred(let reminder, _): return reminder
        default: return nil
        }
    }
    public var isResting: Bool { if case .resting = phase { return true }; return false }
    public var graceRemaining: Double { grace }
    public func remaining(_ kind: BreakKind) -> Double {
        if settings.timingModel == .rounds {
            if let due = roundRestKind { return due == kind ? (kind == .short ? shortCooldown : longCooldown) : settings.shortInterval }
            return max(0, settings.shortInterval - shortElapsed)
        }
        let intervalRemaining = max(0, settings.interval(kind) - (kind == .short ? shortElapsed : longElapsed))
        let cooldown = kind == .short ? shortCooldown : longCooldown
        // Both the usage interval and early-end cooldown must expire before a reminder is due.
        return max(intervalRemaining, cooldown)
    }
    public var nextKind: BreakKind? {
        let enabled = displayKinds
        return enabled.min { remaining($0) < remaining($1) || (remaining($0) == remaining($1) && $0 == .long) }
    }
    private func isDue(_ kind: BreakKind) -> Bool {
        displayKinds.contains(kind) && settings.enabled(kind) && remaining(kind) == 0
    }
    public func tick(seconds: Double, now: Date) {
        let delta = max(0, seconds)
        if case .until(let date) = pause, now >= date { pause = nil; grace = 30; warnedKind = nil }
        let workingTime = settings.isWorkingTime(now)
        outsideSchedule = !workingTime
        // A manual break can span the start of a scheduled work session.
        // Retain its progress and any pending plan until the break settles.
        if priorWorkingTime == false && workingTime {
            reset(.long); completedRounds = 0; warnedKind = nil; grace = 30
            if reminder == nil {
                roundRestKind = nil; phase = .working; applyPending(now: now)
            }
        }
        if priorWorkingTime == true && !workingTime {
            // Away transitions retain the reminder and settle it once on return.
            if !away, case .resting(let r) = phase { record(r, .interrupted, now, includeDuration: false) }
            phase = .working; effects.append(.hide); warnedKind = nil
            if !away { applyPending(now: now) }
        }
        priorWorkingTime = workingTime
        guard pause == nil, !away else { return }
        if case .resting(var r) = phase {
            let used = min(delta, max(0, r.target - r.elapsed))
            recordDurationSplit(seconds: used, ending: now, kind: r.kind, outcome: .usage, reminderID: r.id, rest: true)
            r.elapsed += used
            if r.elapsed >= r.target {
                record(r, .completed, now, includeDuration: false); settleRest(r)
                phase = .working; warnedKind = nil; effects += [.hide, .completed(r.kind)]
                applyPending(now: now)
            } else { phase = .resting(r) }
            return
        }
        guard workingTime else { return }
        // Stop accumulating at the interval without discarding usage retained
        // from a longer interval when the user changes settings.
        if settings.timingModel != .rounds || roundRestKind == nil {
            shortElapsed = max(shortElapsed, min(settings.shortInterval, shortElapsed + delta))
        }
        if settings.timingModel == .dual { longElapsed = max(longElapsed, min(settings.longInterval, longElapsed + delta)) }
        if settings.timingModel == .rounds && roundRestKind == nil && shortElapsed >= settings.shortInterval {
            completedRounds += 1
            roundRestKind = completedRounds >= settings.rounds ? .long : .short
            appendRecord(Record(date: now, kind: nil, outcome: .focusCompleted))
        }
        recordDurationSplit(seconds: delta, ending: now, kind: nil, outcome: .usage, reminderID: nil, rest: false)
        shortCooldown = max(0, shortCooldown - delta); longCooldown = max(0, longCooldown - delta)
        if case .deferred(let r, let remaining) = phase {
            if r.kind == .short && isDue(.long) {
                phase = .working; effects.append(.hide); warnedKind = nil
            } else if remaining > delta {
                phase = .deferred(r, remaining - delta)
                // Recovery grace overlaps the postponement; it must not add
                // another delay once the promised postponement expires.
                if !suppressed { grace = max(0, grace - delta) }
                return
            }
            else {
                if suppressed { phase = .deferred(r, 0); return }
                if grace > 0 { tickGrace(delta, kind: r.kind); phase = .deferred(r, 0); return }
                present(r); return
            }
        }
        guard !suppressed else { return }
        if grace > 0 { tickGrace(delta, kind: nextKind); return }
        if case .waiting(let r) = phase {
            if r.kind == .short && isDue(.long) {
                effects.append(.hide); present(makeReminder(.long))
            }
            return
        }
        let due: BreakKind?
        if isDue(.long) { due = .long }
        else if isDue(.short) { due = .short }
        else { due = nil }
        if let due { present(makeReminder(due)); return }
        if let next = nextKind, settings.prewarning > 0, remaining(next) <= settings.prewarning, warnedKind != next {
            warnedKind = next; phase = .warning(next); effects.append(.warning(next))
        }
    }
    private func present(_ value: Reminder) {
        if settings.breakStartMode == .automatic { phase = .resting(value) }
        else { phase = .waiting(value) }
        effects.append(.show(value))
    }
    private func makeReminder(_ kind: BreakKind) -> Reminder {
        var reminder = Reminder(kind: kind, target: settings.duration(kind))
        reminder.planID = settings.planID; reminder.basePlanID = settings.basePlanID; reminder.timingModel = settings.timingModel
        reminder.ideaIndex = ((lastIdea[kind] ?? -1) + 1) % 5
        lastIdea[kind] = reminder.ideaIndex
        return reminder
    }
    private func tickGrace(_ delta: Double, kind: BreakKind?) {
        grace = max(0, grace - delta)
        if let kind, remaining(kind) == 0, settings.prewarning > 0,
           grace <= settings.prewarning, warnedKind != kind {
            warnedKind = kind; effects.append(.warning(kind))
        }
    }
    public func start(now: Date) {
        guard case .waiting(let r) = phase else { return }
        phase = .resting(r)
    }
    public func startNow(_ kind: BreakKind, now: Date) {
        guard !away, settings.enabled(kind) else { return }
        // Manual start explicitly overrides manual pause but not the session/sleep boundary.
        pause = nil
        if case .resting = phase { finish(now: now) }
        guard settings.enabled(kind) else { return }
        if settings.timingModel == .rounds {
            if let due = roundRestKind, due != kind { return }
            if roundRestKind == nil { roundRestKind = kind }
        }
        phase = .resting(makeReminder(kind))
        effects.append(.show(reminder!))
    }
    public func postpone(now: Date) {
        guard var r = reminder, r.postponements < settings.postponeLimit else { return }
        if r.elapsed > 0 {
            // Per-segment duration has already been recorded; only emit the outcome here.
            record(r, .postponed, now, includeDuration: false)
        } else { appendRecord(Record(date: now, kind: r.kind, outcome: .postponed, reminderID: r.id)) }
        r.postponements += 1; r.elapsed = 0
        phase = .deferred(r, settings.postponement(r.kind)); effects.append(.hide)
    }
    public func skip(now: Date) {
        guard let r = reminder else { return }
        // Explicit skips consume the reminder; closing a running timer uses finish instead.
        // Measured rest segments are already recorded, so do not add them again here.
        record(r, .skipped, now, includeDuration: false); settleRest(r)
        phase = .working; warnedKind = nil; effects.append(.hide); applyPending(now: now)
    }
    private func settleRest(_ r: Reminder) {
        reset(r.kind)
        if settings.timingModel == .rounds {
            roundRestKind = nil
            if r.kind == .long { completedRounds = 0 }
        }
    }
    public func finish(now: Date) {
        guard case .resting(let r) = phase else { return }
        record(r, .ended, now, includeDuration: false)
        if settings.timingModel != .rounds && r.elapsed >= settings.shortDuration { shortElapsed = 0 }
        if r.kind == .long && r.elapsed >= r.target { longElapsed = 0 }
        if r.kind == .short { shortCooldown = settings.postponement(.short) } else { longCooldown = settings.postponement(.long) }
        // A voluntary early break must not manufacture a completed focus round.
        if settings.timingModel == .rounds && roundRestKind == nil { shortElapsed = 0 }
        phase = .working; warnedKind = nil; effects.append(.hide); applyPending(now: now)
    }
    public func setPause(_ mode: PauseMode?, now: Date) {
        if case .resting(let r) = phase { record(r, .interrupted, now, includeDuration: false); phase = .deferred(r, 0) }
        if case .waiting(let r) = phase { phase = .deferred(r, 0) }
        if case .warning = phase { phase = .working }
        pause = mode; grace = 30; warnedKind = nil; effects.append(.hide)
    }
    public func setSuppressed(_ value: Bool) {
        guard value != suppressed else { return }
        suppressed = value
        if value {
            if case .waiting(let r) = phase { phase = .deferred(r, 0); effects.append(.hide) }
            else if !isResting, warnedKind != nil {
                // Grace warnings can be visible while the phase is working.
                if case .warning = phase { phase = .working }
                effects.append(.hide)
            }
        } else {
            grace = 30; warnedKind = nil
            if case .waiting = phase { phase = .working }
        }
    }
    public func beginAway(at start: Date) {
        guard !away else { return }
        away = true; awayStarted = start
        if case .resting(let r) = phase { interruptedReminder = r }
        effects.append(.hide)
    }
    public func endAway(now: Date, minimumShort: Double) {
        guard away else { return }
        let seconds = max(0, now.timeIntervalSince(awayStarted ?? now))
        // A pause already recorded the interruption, but its deferred reminder
        // still carries measured rest that qualifies together with time away.
        let interrupted = interruptedReminder ?? reminder.flatMap { $0.elapsed > 0 ? $0 : nil }
        let combined = seconds + (interrupted?.elapsed ?? 0)
        away = false; awayStarted = nil
        if let r = interruptedReminder { record(r, .interrupted, now, includeDuration: false) }
        interruptedReminder = nil
        let qualifiesLong = combined >= settings.longDuration
        let qualifiesShort = combined >= (settings.timingModel == .dual ? minimumShort : settings.shortDuration)
        if seconds == 0 { appendRecord(Record(date: now, kind: nil, outcome: .natural)) }
        else { recordDurationSplit(seconds: seconds, ending: now, kind: nil, outcome: .natural, reminderID: nil, rest: false) }
        if case .deferred(var r, let delay) = phase, r.elapsed > 0 {
            r.elapsed = min(r.target, combined); phase = .deferred(r, delay)
        }
        switch settings.timingModel {
        case .dual:
            if qualifiesLong { reset(.long) }
            else if qualifiesShort { reset(.short) }
            if qualifiesShort || qualifiesLong || isResting { phase = .working }
            else if case .waiting(let r) = phase { phase = .deferred(r, 0) }
        case .single:
            if qualifiesShort { reset(.short); phase = .working }
            else if case .resting(var r) = phase {
                r.elapsed = min(r.target, combined); phase = .deferred(r, 0)
            } else if case .waiting(let r) = phase { phase = .deferred(r, 0) }
        case .rounds:
            if qualifiesLong {
                reset(.long); completedRounds = 0; roundRestKind = nil; phase = .working
            } else if let due = roundRestKind {
                let meetsDue = combined >= settings.duration(due)
                if meetsDue { reset(due); roundRestKind = nil; phase = .working }
                else if case .resting(var r) = phase {
                    r.elapsed = min(r.target, combined); phase = .deferred(r, 0)
                } else if case .waiting(let r) = phase { phase = .deferred(r, 0) }
            } else if qualifiesShort {
                reset(.short); phase = .working
            } else if case .resting(var r) = phase {
                r.elapsed = min(r.target, combined); phase = .deferred(r, 0)
            }
        }
        if let interrupted, pendingPlan != nil, reminder == nil,
           combined < interrupted.target {
            var retained = interrupted; retained.elapsed = combined
            phase = .deferred(retained, 0)
        }
        if pendingPlan != nil && reminder == nil { applyPending(now: now) }
        grace = 30; warnedKind = nil
    }
    private func reset(_ kind: BreakKind) {
        shortElapsed = 0; shortCooldown = 0
        if kind == .long { longElapsed = 0; longCooldown = 0 }
    }
    private func record(_ r: Reminder, _ outcome: Outcome, _ now: Date, includeDuration: Bool = true) {
        appendRecord(Record(date: now, kind: r.kind, outcome: outcome, seconds: includeDuration ? r.elapsed : 0, reminderID: r.id))
    }
    private func recordDurationSplit(seconds: Double, ending: Date, kind: BreakKind?, outcome: Outcome, reminderID: UUID?, rest: Bool) {
        guard seconds > 0 else { return }
        var start = ending.addingTimeInterval(-seconds)
        var remaining = seconds
        while start < ending {
            guard let day = Calendar.current.dateInterval(of: .day, for: start) else { return }
            let segmentEnd = min(day.end, ending)
            // Use local calendar day boundaries, including 23/25-hour DST days.
            let date = segmentEnd == day.end ? segmentEnd.addingTimeInterval(-0.001) : segmentEnd
            // Keep the measured total exact instead of round-tripping the final
            // segment through Date's floating-point timestamp precision.
            let duration = segmentEnd == ending ? remaining : segmentEnd.timeIntervalSince(start)
            // usage records with a reminderID represent measured rest segments.
            appendRecord(Record(date: date, kind: kind, outcome: outcome, seconds: duration, reminderID: rest ? reminderID : nil))
            start = segmentEnd; remaining -= duration
        }
    }
    private func appendRecord(_ record: Record) {
        var record = record
        record.planID = settings.planID; record.timingModel = settings.timingModel; record.basePlanID = settings.basePlanID
        records.append(record)
    }
    public func drain() -> ([EngineEffect], [Record]) {
        let result = (effects, records); effects.removeAll(); records.removeAll(); return result
    }
    public func snapshot(now: Date) -> Snapshot {
        var result = Snapshot(); result.shortElapsed = shortElapsed; result.longElapsed = longElapsed
        result.pause = pause; result.savedAt = now
        if case .resting(let r) = phase { result.activeReminder = r }
        // Restore waiting cards as due deferred reminders so startup grace still
        // applies without losing the logical reminder or its postponement budget.
        if case .waiting(let r) = phase { result.deferredReminder = r; result.deferredRemaining = 0 }
        if case .deferred(let r, let remaining) = phase { result.deferredReminder = r; result.deferredRemaining = remaining }
        result.shortCooldown = shortCooldown; result.longCooldown = longCooldown
        result.completedRounds = completedRounds; result.roundRestKind = roundRestKind; result.pendingPlan = pendingPlan
        return result
    }
}
