import Foundation
import Testing
@testable import TickRestCore

struct StatisticsTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }
    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }
    private func record(day: String, outcome: Outcome, seconds: Double = 0, rest: Bool = false) -> Record {
        var value = Record(date: date(2026, 10, 11), kind: rest ? .short : nil,
                           outcome: outcome, seconds: seconds, reminderID: rest ? UUID() : nil)
        value.day = day
        return value
    }

    @Test func startsWithTodayAndRelativeRangesRollOver() {
        let now = date(2026, 12, 31)
        var selection = StatisticsSelection(now: now)
        #expect(selection.preset == .today)
        #expect(selection.range(now: now, calendar: calendar).startDay == "2026-12-31")
        let tomorrow = date(2027, 1, 1)
        #expect(selection.range(now: tomorrow, calendar: calendar).startDay == "2027-01-01")
        selection.select(.yesterday, now: tomorrow, calendar: calendar)
        let yesterday = selection.range(now: tomorrow, calendar: calendar)
        #expect(yesterday.startDay == "2026-12-31" && yesterday.endDay == "2026-12-31")
    }

    @Test func rollingRangesIncludeTodayAcrossMonthAndYear() {
        let now = date(2027, 1, 3)
        var selection = StatisticsSelection(now: now)
        selection.select(.last7, now: now, calendar: calendar)
        let week = selection.range(now: now, calendar: calendar)
        #expect(week.startDay == "2026-12-28" && week.endDay == "2027-01-03")
        selection.select(.last30, now: now, calendar: calendar)
        let month = selection.range(now: now, calendar: calendar)
        #expect(month.startDay == "2026-12-05" && month.endDay == "2027-01-03")
        let next = selection.range(now: date(2027, 1, 4), calendar: calendar)
        #expect(next.startDay == "2026-12-06" && next.endDay == "2027-01-04")
    }

    @Test func presetsUseCalendarDaysAcrossDaylightSaving() {
        var dstCalendar = Calendar(identifier: .gregorian)
        dstCalendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = dstCalendar.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 12))!
        var selection = StatisticsSelection(now: now)
        selection.select(.yesterday, now: now, calendar: dstCalendar)
        let yesterday = selection.range(now: now, calendar: dstCalendar)
        #expect(yesterday.startDay == "2026-03-08" && yesterday.endDay == "2026-03-08")
        selection.select(.last7, now: now, calendar: dstCalendar)
        let week = selection.range(now: now, calendar: dstCalendar)
        #expect(week.startDay == "2026-03-03" && week.endDay == "2026-03-09")
        #expect(week.end.timeIntervalSince(week.start) == 6 * 86400 - 3600)
    }

    @Test func inclusiveRangeAggregatesAllMetricsAndExcludesAdjacentDays() {
        let range = StatisticsDateRange(start: date(2026, 10, 1), end: date(2026, 10, 3), calendar: calendar)
        let records = [
            record(day: "2026-09-30", outcome: .usage, seconds: 999),
            record(day: "2026-10-01", outcome: .usage, seconds: 60),
            record(day: "2026-10-02", outcome: .usage, seconds: 40),
            record(day: "2026-10-03", outcome: .usage, seconds: 20, rest: true),
            record(day: "2026-10-01", outcome: .natural, seconds: 90),
            record(day: "2026-10-01", outcome: .completed),
            record(day: "2026-10-03", outcome: .completed),
            record(day: "2026-10-02", outcome: .skipped),
            record(day: "2026-10-03", outcome: .ended),
            record(day: "2026-10-02", outcome: .postponed),
            record(day: "2026-10-04", outcome: .completed)
        ]
        let summary = StatisticsSummary(records: records, range: range)
        #expect(summary.hasRecords)
        #expect(summary.usage == 100 && summary.rest == 20 && summary.natural == 90)
        #expect(summary.completed == 2 && summary.skipped == 1 && summary.ended == 1)
    }

    @Test func rangeKeepsSavedDayEvenWhenTimestampFallsOutside() {
        // A saved local day remains authoritative after the user's time zone changes.
        let range = StatisticsDateRange(start: date(2026, 10, 1), end: date(2026, 10, 1), calendar: calendar)
        let summary = StatisticsSummary(records: [record(day: "2026-10-01", outcome: .usage, seconds: 50)], range: range)
        #expect(summary.usage == 50)
    }

    @Test func emptyAndReversedRangesReturnZero() {
        let records = [record(day: "2026-10-02", outcome: .usage, seconds: 50)]
        for range in [
            StatisticsDateRange(start: date(2026, 10, 4), end: date(2026, 10, 4), calendar: calendar),
            StatisticsDateRange(start: date(2026, 10, 3), end: date(2026, 10, 1), calendar: calendar)
        ] {
            let summary = StatisticsSummary(records: records, range: range)
            #expect(!summary.hasRecords)
            #expect(summary.usage == 0 && summary.rest == 0 && summary.natural == 0)
            #expect(summary.completed == 0 && summary.skipped == 0 && summary.ended == 0)
        }
    }

    @Test func customRangeStartsFromSelectedPresetAndStaysFixed() {
        let now = date(2026, 10, 11)
        var selection = StatisticsSelection(now: now)
        selection.select(.last7, now: now, calendar: calendar)
        let week = selection.range(now: now, calendar: calendar)
        selection.select(.custom, now: now, calendar: calendar)
        #expect(selection.range(now: now, calendar: calendar) == week)
        #expect(selection.range(now: date(2026, 10, 12), calendar: calendar) == week)
        selection.setCustomStart(date(2026, 10, 3), now: now, calendar: calendar)
        #expect(selection.range(now: now, calendar: calendar).startDay == "2026-10-03")
    }

    @Test func customDatesAdjustOtherEndpointAndClampToRetentionAndToday() {
        let now = date(2026, 10, 11)
        var selection = StatisticsSelection(now: now)
        selection.setCustomEnd(date(2026, 10, 1), now: now, calendar: calendar)
        var range = selection.range(now: now, calendar: calendar)
        #expect(range.startDay == "2026-10-01" && range.endDay == "2026-10-01")
        selection.setCustomStart(date(2026, 10, 5), now: now, calendar: calendar)
        range = selection.range(now: now, calendar: calendar)
        #expect(range.startDay == "2026-10-05" && range.endDay == "2026-10-05")
        selection.setCustomEnd(date(2027, 1, 1), now: now, calendar: calendar)
        #expect(selection.range(now: now, calendar: calendar).endDay == "2026-10-11")
        selection.setCustomStart(date(2025, 1, 1), now: now, calendar: calendar)
        let available = StatisticsDateRange.availableDates(now: now, calendar: calendar)
        #expect(selection.range(now: now, calendar: calendar).start == available.lowerBound)
        #expect(available.lowerBound == calendar.startOfDay(for: now.addingTimeInterval(-DataStore.recordRetention)))
        let later = date(2026, 10, 12)
        #expect(selection.range(now: later, calendar: calendar).start == StatisticsDateRange.availableDates(now: later, calendar: calendar).lowerBound)
    }

    @Test func midnightRestUsesSplitDurationsAndCompletionDay() {
        let midnight = Calendar.current.startOfDay(for: Date())
        let before = midnight.addingTimeInterval(-10)
        let after = midnight.addingTimeInterval(10)
        let engine = Engine(settings: Settings())
        engine.startNow(.short, now: before)
        engine.tick(seconds: 20, now: after)
        let yesterday = StatisticsSummary(records: engine.records, range: StatisticsDateRange(start: before, end: before))
        let today = StatisticsSummary(records: engine.records, range: StatisticsDateRange(start: after, end: after))
        let both = StatisticsSummary(records: engine.records, range: StatisticsDateRange(start: before, end: after))
        #expect(yesterday.rest == 10 && yesterday.completed == 0)
        #expect(today.rest == 10 && today.completed == 1)
        #expect(both.rest == 20 && both.completed == 1)
        #expect(TodaySummary(records: engine.records, now: after).rest == today.rest)
    }

    @Test func midnightUsageAndAwaySumWithoutDuplication() {
        let midnight = Calendar.current.startOfDay(for: Date())
        let before = midnight.addingTimeInterval(-10)
        let after = midnight.addingTimeInterval(10)
        let engine = Engine(settings: Settings())
        engine.tick(seconds: 20, now: after)
        engine.beginAway(at: before)
        engine.endAway(now: after, minimumShort: 20)
        let both = StatisticsSummary(records: engine.records, range: StatisticsDateRange(start: before, end: after))
        #expect(both.usage == 20 && both.natural == 20 && both.rest == 0)
        #expect(both.completed == 0)
    }
}
