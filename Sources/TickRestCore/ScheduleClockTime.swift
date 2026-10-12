import Foundation

/// Converts stored wall-clock minutes for time-only controls, independent of day length.
public enum ScheduleClockTime {
    public static func date(minutes: Int, on day: Date = Date(), calendar: Calendar = .current) -> Date {
        let minutes = min(1439, max(0, minutes))
        let components = DateComponents(hour: minutes / 60, minute: minutes % 60, second: 0)
        // A missing spring-forward time uses its next valid occurrence. The
        // picker displays only hour/minute, so the stored time remains editable.
        return calendar.nextDate(after: calendar.startOfDay(for: day).addingTimeInterval(-1),
                                 matching: components, matchingPolicy: .strict,
                                 repeatedTimePolicy: .first) ?? day
    }
}
