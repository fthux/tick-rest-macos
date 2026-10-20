import Foundation
import Testing
@testable import TickRestCore

struct CalendarPersistenceTests {
    private func calendar(_ id: Calendar.Identifier, offset: Int = 0) -> Calendar {
        var result = Calendar(identifier: id)
        result.timeZone = TimeZone(secondsFromGMT: offset)!
        return result
    }
    private func legacyKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    @Test func dayKeysAndStatisticsIgnoreCalendarIdentifierButRespectTimeZone() throws {
        let utc = calendar(.gregorian)
        let date = try #require(utc.date(from: DateComponents(year: 2024, month: 2, day: 29, hour: 23)))
        for id in [Calendar.Identifier.buddhist, .hebrew, .japanese, .chinese, .islamic] {
            let local = calendar(id, offset: 8 * 3600)
            #expect(Record.dayKey(date, calendar: local) == "2024-03-01")
            var record = Record(date: date, kind: nil, outcome: .usage, seconds: 60)
            record.day = Record.dayKey(date, calendar: local)
            let range = StatisticsDateRange(start: date, end: date, calendar: local)
            #expect(range.startDay == "2024-03-01" && range.endDay == "2024-03-01")
            #expect(StatisticsSummary(records: [record], range: range).usage == 60)
        }
        #expect(Record.dayKey(date, calendar: calendar(.buddhist, offset: -8 * 3600)) == "2024-02-29")
    }

    @Test(arguments: [1, 2])
    func legacyCalendarsMigrateWithoutLosingHistoryOrSettings(_ version: Int) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DataStore(url: directory.appendingPathComponent("state.json"))
        var data = SavedData(); data.version = version
        data.settings.onboardingComplete = true; data.settings.language = "ja"
        data.snapshot.shortElapsed = 123
        let utc = calendar(.gregorian)
        let leap = try #require(utc.date(from: DateComponents(year: 2024, month: 2, day: 29, hour: 12)))
        let hebrew = calendar(.hebrew)
        let month13 = try #require(hebrew.date(from: DateComponents(year: 5786, month: 13, day: 1)))
        // A Gregorian-looking Buddhist year also needs migration, not just invalid dates.
        let ordinary = try #require(utc.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 23)))
        for (date, source) in [(leap, calendar(.buddhist)), (month13, hebrew),
                               (ordinary, calendar(.buddhist, offset: 8 * 3600)), (ordinary, utc)] {
            var record = Record(date: date, kind: .short, outcome: .completed, seconds: 20)
            record.day = legacyKey(date, calendar: source)
            record.timeZoneOffset = source.timeZone.secondsFromGMT(for: date)
            data.records.append(record)
        }
        try store.save(data)
        let original = try Data(contentsOf: store.url)
        let loaded = store.load()
        #expect(store.loadErrorKey == nil && loaded.version == 3)
        #expect(loaded.settings == data.settings && loaded.snapshot.shortElapsed == 123)
        #expect(loaded.records.map(\.id) == data.records.map(\.id))
        #expect(loaded.records.map(\.seconds) == [20, 20, 20, 20])
        #expect(loaded.records[0].day == "2024-02-29")
        #expect(loaded.records[1].day == Record.dayKey(month13, calendar: utc))
        #expect(loaded.records[2].day == "2026-10-22")
        #expect(loaded.records[3].day == "2026-10-21")
        #expect(try Data(contentsOf: directory.appendingPathComponent("state-v\(version)-backup.json")) == original)
        try store.save(loaded)
        let reloaded = store.load()
        #expect(reloaded.records.map(\.day) == loaded.records.map(\.day))
        #expect(reloaded.records.map(\.id) == loaded.records.map(\.id))
    }

    @Test func migrationDoesNotSilentlyAcceptAnUnrelatedInvalidDate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DataStore(url: directory.appendingPathComponent("state.json"))
        var data = SavedData(); data.version = 2
        let date = try #require(calendar(.gregorian).date(from: DateComponents(year: 2026, month: 10, day: 21)))
        var record = Record(date: date, kind: nil, outcome: .usage, seconds: 1)
        record.day = "2026-02-29"; data.records = [record]
        try store.save(data)
        _ = store.load()
        #expect(store.loadErrorKey == "error.load")
    }
}
