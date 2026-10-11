import Foundation

public enum BreakKind: String, Codable, CaseIterable {
    case short, long
    public var title: String { L10n.text("break.\(rawValue)") }
    public var postponement: Double { self == .short ? 120 : 300 }
}
public enum ReminderStyle: String, Codable, CaseIterable { case gentle, overlay }
public enum BreakStartMode: String, Codable, CaseIterable { case automatic, manual }
public enum DisplayScope: String, Codable, CaseIterable { case all, current }
public enum AppTheme: String, Codable, CaseIterable { case system, light, dark }
public enum ReminderSound: String, Codable, CaseIterable {
    case glass = "Glass", ping = "Ping", pop = "Pop", tink = "Tink", purr = "Purr", hero = "Hero"
    public var title: String { L10n.text("sound.\(rawValue.lowercased())") }
}

public struct Settings: Codable, Equatable {
    public var shortEnabled = true
    public var longEnabled = true
    public var shortInterval: Double = 1200
    public var shortDuration: Double = 20
    public var longInterval: Double = 3600
    public var longDuration: Double = 300
    public var prewarning: Double = 10
    public var style: ReminderStyle = .gentle
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
    public var theme: AppTheme = .system
    public var language = "system"
    public var onboardingComplete = false
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case shortEnabled, longEnabled, shortInterval, shortDuration, longInterval, longDuration
        case prewarning, style, breakStartMode, displayScope, sound, reminderSound, detectIdle, idleTimeout, avoidFullscreen
        case scheduleEnabled, weekdays, scheduleStart, scheduleEnd, showCountdown, theme, language, onboardingComplete
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
        theme = try values.decode(AppTheme.self, forKey: .theme)
        language = try values.decode(String.self, forKey: .language)
        onboardingComplete = try values.decode(Bool.self, forKey: .onboardingComplete)
    }
    public func enabled(_ kind: BreakKind) -> Bool { kind == .short ? shortEnabled : longEnabled }
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
        if !(60...7200).contains(shortInterval) || !(10...300).contains(shortDuration)
            || !(60...14400).contains(longInterval) || !(60...1800).contains(longDuration) {
            return "validation.range"
        }
        if longEnabled && shortEnabled && longInterval < shortInterval { return "validation.interval" }
        if longEnabled && shortEnabled && longDuration < shortDuration { return "validation.duration" }
        if !prewarning.isFinite || prewarning < 0
            || (shortEnabled && prewarning >= shortInterval)
            || (longEnabled && prewarning >= longInterval) { return "validation.prewarning" }
        if !(0..<1440).contains(scheduleStart) || !(0..<1440).contains(scheduleEnd)
            || !weekdays.isSubset(of: Set(1...7))
            || (scheduleEnabled && (weekdays.isEmpty || scheduleStart == scheduleEnd)) { return "validation.schedule" }
        return nil
    }
}

public enum Outcome: String, Codable { case completed, skipped, ended, postponed, natural, interrupted, usage }
public struct Record: Codable, Identifiable {
    public var id: UUID
    public var reminderID: UUID?
    public var date: Date
    public var day: String
    public var timeZoneOffset: Int
    public var kind: BreakKind?
    public var outcome: Outcome
    public var seconds: Double
    public init(date: Date, kind: BreakKind?, outcome: Outcome, seconds: Double = 0, reminderID: UUID? = nil) {
        self.id = UUID(); self.date = date; self.kind = kind; self.outcome = outcome
        self.seconds = seconds; self.reminderID = reminderID
        self.day = Self.dayKey(date)
        self.timeZoneOffset = TimeZone.current.secondsFromGMT(for: date)
    }
    public static func dayKey(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
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
    public var idea: String { L10n.text("idea.\(kind.rawValue).\(ideaIndex)") }
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
    public init() {}
}
