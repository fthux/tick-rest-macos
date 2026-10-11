import Foundation

public enum StatisticsPreset: String, CaseIterable, Identifiable {
    case today, yesterday, last7, last30, custom
    public var id: String { rawValue }
}

/// An inclusive range of local calendar dates, matching the day saved in each record.
public struct StatisticsDateRange: Equatable {
    public let start: Date
    public let end: Date
    public let startDay: String
    public let endDay: String

    public init(start: Date, end: Date, calendar: Calendar = .current) {
        self.start = calendar.startOfDay(for: start)
        self.end = calendar.startOfDay(for: end)
        startDay = Record.dayKey(start, calendar: calendar)
        endDay = Record.dayKey(end, calendar: calendar)
    }

    public func contains(day: String) -> Bool {
        startDay <= day && day <= endDay
    }

    public static func availableDates(now: Date, calendar: Calendar = .current) -> ClosedRange<Date> {
        let oldest = calendar.startOfDay(for: now.addingTimeInterval(-DataStore.recordRetention))
        return oldest...calendar.startOfDay(for: now)
    }
}

/// Session-only selection. Relative presets resolve again on each refresh.
public struct StatisticsSelection {
    public private(set) var preset: StatisticsPreset = .today
    public private(set) var customStart: Date
    public private(set) var customEnd: Date

    public init(now: Date = Date()) {
        customStart = now
        customEnd = now
    }

    public func range(now: Date = Date(), calendar: Calendar = .current) -> StatisticsDateRange {
        let today = calendar.startOfDay(for: now)
        switch preset {
        case .today: return StatisticsDateRange(start: today, end: today, calendar: calendar)
        case .yesterday:
            let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
            return StatisticsDateRange(start: yesterday, end: yesterday, calendar: calendar)
        case .last7, .last30:
            let start = calendar.date(byAdding: .day, value: preset == .last7 ? -6 : -29, to: today)!
            return StatisticsDateRange(start: start, end: today, calendar: calendar)
        case .custom:
            let start = clamped(customStart, now: now, calendar: calendar)
            let end = clamped(customEnd, now: now, calendar: calendar)
            return StatisticsDateRange(start: min(start, end), end: end, calendar: calendar)
        }
    }

    public mutating func select(_ value: StatisticsPreset, now: Date = Date(), calendar: Calendar = .current) {
        if value == .custom && preset != .custom {
            let current = range(now: now, calendar: calendar)
            customStart = current.start
            customEnd = current.end
        }
        preset = value
    }

    public mutating func setCustomStart(_ date: Date, now: Date = Date(), calendar: Calendar = .current) {
        select(.custom, now: now, calendar: calendar)
        customStart = clamped(date, now: now, calendar: calendar)
        customEnd = max(customStart, clamped(customEnd, now: now, calendar: calendar))
    }

    public mutating func setCustomEnd(_ date: Date, now: Date = Date(), calendar: Calendar = .current) {
        select(.custom, now: now, calendar: calendar)
        customEnd = clamped(date, now: now, calendar: calendar)
        customStart = min(customEnd, clamped(customStart, now: now, calendar: calendar))
    }

    private func clamped(_ date: Date, now: Date, calendar: Calendar) -> Date {
        let available = StatisticsDateRange.availableDates(now: now, calendar: calendar)
        return min(available.upperBound, max(available.lowerBound, calendar.startOfDay(for: date)))
    }
}
