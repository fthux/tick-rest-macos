import Foundation

public enum BreakKind: String, Codable, CaseIterable {
    case short, long
    public var title: String { L10n.text("break.\(rawValue)") }
    public var postponement: Double { self == .short ? 120 : 300 }
}
public enum ReminderStyle: String, Codable, CaseIterable { case gentle, overlay }
public enum GentleReminderSize: String, Codable, CaseIterable { case normal, small, mini }
public enum BreakStartMode: String, Codable, CaseIterable { case automatic, manual }
public enum DisplayScope: String, Codable, CaseIterable { case all, current }
public enum AppTheme: String, Codable, CaseIterable { case system, light, dark }
public enum ReminderSound: String, Codable, CaseIterable {
    case glass = "Glass", ping = "Ping", pop = "Pop", tink = "Tink", purr = "Purr", hero = "Hero"
    public var title: String { L10n.text("sound.\(rawValue.lowercased())") }
}

public struct Settings: Codable, Equatable {
    public var planID: RestPlanID = .tickrest
    public var basePlanID: RestPlanID?
    public var timingModel: TimingModel = .dual
    public var rounds = RestPlan().rounds
    public var shortPostpone: Double = RestPlan().shortPostpone
    public var longPostpone: Double = RestPlan().longPostpone
    public var singlePostpone: Double = RestPlan().singlePostpone
    public var postponeLimit = RestPlan().postponeLimit
    public var shortEnabled = RestPlan().shortEnabled
    public var longEnabled = RestPlan().longEnabled
    public var shortInterval: Double = RestPlan().shortInterval
    public var shortDuration: Double = RestPlan().shortDuration
    public var longInterval: Double = RestPlan().longInterval
    public var longDuration: Double = RestPlan().longDuration
    public var prewarning: Double = 10
    public var style: ReminderStyle = .gentle
    public var gentleReminderSize: GentleReminderSize = .normal
    public var breakStartMode: BreakStartMode = .automatic
    public var displayScope: DisplayScope = .all
    public var sound = false
    public var reminderSound: ReminderSound = .glass
    public var detectIdle = true
    public var idleTimeout: Double = 300
    public var avoidFullscreen = true
    public var scheduleEnabled = false
    public var weekdays: Set<Int> = [2, 3, 4, 5, 6]
    public var scheduleStart = 9 * 60
    public var scheduleEnd = 18 * 60
    public var showCountdown = true
    public var showStatusDot = true
    public var statusDotPalette = StatusDotPalette()
    public var theme: AppTheme = .system
    public var language = "system"
    public var onboardingComplete = false
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case planID, basePlanID, timingModel, rounds, shortPostpone, longPostpone, singlePostpone, postponeLimit
        case shortEnabled, longEnabled, shortInterval, shortDuration, longInterval, longDuration
        case prewarning, style, gentleReminderSize, breakStartMode, displayScope, sound, reminderSound, detectIdle, idleTimeout, avoidFullscreen
        case scheduleEnabled, weekdays, scheduleStart, scheduleEnd, showCountdown, theme, language, onboardingComplete
        case showStatusDot, statusDotPalette
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        shortEnabled = try values.decode(Bool.self, forKey: .shortEnabled)
        longEnabled = try values.decode(Bool.self, forKey: .longEnabled)
        shortInterval = try values.decode(Double.self, forKey: .shortInterval)
        shortDuration = try values.decode(Double.self, forKey: .shortDuration)
        longInterval = try values.decode(Double.self, forKey: .longInterval)
        longDuration = try values.decode(Double.self, forKey: .longDuration)
        prewarning = try values.decode(Double.self, forKey: .prewarning)
        style = try values.decode(ReminderStyle.self, forKey: .style)
        gentleReminderSize = try values.decodeIfPresent(GentleReminderSize.self, forKey: .gentleReminderSize) ?? .normal
        // Existing configurations adopt automatic starts without losing other preferences.
        breakStartMode = try values.decodeIfPresent(BreakStartMode.self, forKey: .breakStartMode) ?? .automatic
        displayScope = try values.decode(DisplayScope.self, forKey: .displayScope)
        sound = try values.decode(Bool.self, forKey: .sound)
        // Preserve the existing tone when loading settings saved before sound selection.
        reminderSound = try values.decodeIfPresent(ReminderSound.self, forKey: .reminderSound) ?? .glass
        detectIdle = try values.decode(Bool.self, forKey: .detectIdle)
        // Older saved settings have no idleTimeout; preserve them and use the new default.
        idleTimeout = values.contains(.idleTimeout) ? try values.decode(Double.self, forKey: .idleTimeout) : 300
        avoidFullscreen = try values.decode(Bool.self, forKey: .avoidFullscreen)
        scheduleEnabled = try values.decode(Bool.self, forKey: .scheduleEnabled)
        weekdays = try values.decode(Set<Int>.self, forKey: .weekdays)
        scheduleStart = try values.decode(Int.self, forKey: .scheduleStart)
        scheduleEnd = try values.decode(Int.self, forKey: .scheduleEnd)
        showCountdown = try values.decode(Bool.self, forKey: .showCountdown)
        showStatusDot = try values.decodeIfPresent(Bool.self, forKey: .showStatusDot) ?? true
        statusDotPalette = (try? values.decode(StatusDotPalette.self, forKey: .statusDotPalette)) ?? StatusDotPalette()
        theme = try values.decode(AppTheme.self, forKey: .theme)
        language = try values.decode(String.self, forKey: .language)
        onboardingComplete = try values.decode(Bool.self, forKey: .onboardingComplete)
        planID = try values.decodeIfPresent(RestPlanID.self, forKey: .planID) ?? .tickrest
        basePlanID = try values.decodeIfPresent(RestPlanID.self, forKey: .basePlanID)
        timingModel = try values.decodeIfPresent(TimingModel.self, forKey: .timingModel) ?? .dual
        rounds = try values.decodeIfPresent(Int.self, forKey: .rounds) ?? 4
        shortPostpone = try values.decodeIfPresent(Double.self, forKey: .shortPostpone) ?? 120
        longPostpone = try values.decodeIfPresent(Double.self, forKey: .longPostpone) ?? 300
        singlePostpone = try values.decodeIfPresent(Double.self, forKey: .singlePostpone) ?? 300
        postponeLimit = try values.decodeIfPresent(Int.self, forKey: .postponeLimit) ?? 2
        if !values.contains(.planID), restPlan != RestPlan.preset(.tickrest) {
            planID = .custom; basePlanID = .tickrest
        }
    }
    public func enabled(_ kind: BreakKind) -> Bool { restPlan.enabled(kind) }
    public func interval(_ kind: BreakKind) -> Double { kind == .short ? shortInterval : longInterval }
    public func duration(_ kind: BreakKind) -> Double { kind == .short ? shortDuration : longDuration }
    public func isWorkingTime(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard scheduleEnabled else { return true }
        let weekday = calendar.component(.weekday, from: date)
        let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        if scheduleStart < scheduleEnd {
            return weekdays.contains(weekday) && minute >= scheduleStart && minute < scheduleEnd
        }
        // Overnight intervals belong to their starting weekday.
        if minute >= scheduleStart { return weekdays.contains(weekday) }
        let previousWeekday = weekday == 1 ? 7 : weekday - 1
        return minute < scheduleEnd && weekdays.contains(previousWeekday)
    }
    public var validationError: String? {
        validationErrorKey.map { L10n.text($0) }
    }
    public var validationErrorKey: String? {
        if !(60...3600).contains(idleTimeout) { return "validation.idle_timeout" }
        if let error = restPlan.validationErrorKey { return error }
        if !prewarning.isFinite || prewarning < 0
            || (enabled(.short) && prewarning >= shortInterval)
            || (enabled(.long) && prewarning >= (timingModel == .rounds ? shortInterval : longInterval)) { return "validation.prewarning" }
        if !(0..<1440).contains(scheduleStart) || !(0..<1440).contains(scheduleEnd)
            || !weekdays.isSubset(of: Set(1...7))
            || (scheduleEnabled && (weekdays.isEmpty || scheduleStart == scheduleEnd)) { return "validation.schedule" }
        return nil
    }
}

public enum Outcome: String, Codable { case completed, skipped, ended, postponed, natural, interrupted, usage, focusCompleted, planChanged, restarted }
public struct Record: Codable, Identifiable {
    public var id: UUID
    public var reminderID: UUID?
    public var date: Date
    public var day: String
    public var timeZoneOffset: Int
    public var kind: BreakKind?
    public var outcome: Outcome
    public var seconds: Double
    public var planID: RestPlanID?
    public var timingModel: TimingModel?
    public var basePlanID: RestPlanID?
    public init(date: Date, kind: BreakKind?, outcome: Outcome, seconds: Double = 0, reminderID: UUID? = nil) {
        self.id = UUID(); self.date = date; self.kind = kind; self.outcome = outcome
        self.seconds = seconds; self.reminderID = reminderID
        self.day = Self.dayKey(date)
        self.timeZoneOffset = TimeZone.current.secondsFromGMT(for: date)
    }
    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
public struct Reminder: Codable, Equatable {
    public var id = UUID()
    public var kind: BreakKind
    public var target: Double
    public var elapsed: Double = 0
    public var postponements = 0
    public var ideaIndex = 0
    public var planID: RestPlanID?
    public var timingModel: TimingModel?
    public var basePlanID: RestPlanID?
    public var title: String {
        var p = RestPlan(); p.id = planID ?? .tickrest; p.baseID = basePlanID; p.model = timingModel ?? .dual
        return p.breakTitle(kind)
    }
    public var idea: String {
        if timingModel == .single && (planID == .eye202020 || basePlanID == .eye202020) { return L10n.text("plan.eye_idea") }
        if timingModel == .single || timingModel == .rounds { return L10n.text("plan.movement_idea") }
        return L10n.text("idea.\(kind.rawValue).\(ideaIndex)")
    }
    public init(kind: BreakKind, target: Double) { self.kind = kind; self.target = target }
}
public enum Phase: Equatable {
    case working, warning(BreakKind), waiting(Reminder), resting(Reminder), deferred(Reminder, Double)
}
public enum PauseMode: Codable, Equatable {
    case until(Date), indefinite
}
public struct Snapshot: Codable {
    public var shortElapsed: Double = 0
    public var longElapsed: Double = 0
    public var pause: PauseMode?
    public var savedAt: Date = Date()
    public var activeReminder: Reminder?
    public var deferredReminder: Reminder?
    public var deferredRemaining: Double?
    public var shortCooldown: Double = 0
    public var longCooldown: Double = 0
    public var completedRounds: Int?
    public var roundRestKind: BreakKind?
    public var pendingPlan: RestPlan?
    public init() {}
}
