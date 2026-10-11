import Foundation
import Testing
@testable import TickRestCore

struct PersistenceValidationTests {
    private func withStore(_ body: (DataStore, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(DataStore(url: directory.appendingPathComponent("state.json")), directory)
    }

    @Test(arguments: ["both-reminders", "orphan-delay", "negative-round", "bad-idea", "round-kind", "pending-warning", "invalid-leap-day"])
    func inconsistentSavedStateIsRejectedAndPreserved(_ corruption: String) throws {
        try withStore { store, directory in
            var saved = SavedData()
            switch corruption {
            case "both-reminders":
                saved.snapshot.activeReminder = Reminder(kind: .short, target: 20)
                saved.snapshot.deferredReminder = Reminder(kind: .short, target: 20)
                saved.snapshot.deferredRemaining = 0
            case "orphan-delay": saved.snapshot.deferredRemaining = 10
            case "negative-round": saved.snapshot.completedRounds = -1
            case "bad-idea":
                var reminder = Reminder(kind: .short, target: 20); reminder.ideaIndex = -1
                saved.snapshot.activeReminder = reminder
            case "round-kind": saved.snapshot.roundRestKind = .short
            case "pending-warning":
                saved.settings.prewarning = 60
                var plan = RestPlan.preset(.eye202020); plan.shortInterval = 60; plan.markCustom()
                saved.snapshot.pendingPlan = plan
            default:
                var record = Record(date: Date(), kind: nil, outcome: .usage, seconds: 1)
                record.day = "2026-02-29"; saved.records = [record]
            }
            try store.save(saved); let original = try Data(contentsOf: store.url)
            _ = store.load(); #expect(store.loadErrorKey == "error.load")
            let backup = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.hasPrefix("state-damaged-") })
            #expect(try Data(contentsOf: backup) == original)
        }
    }

    @Test func legitimateHistoricalValuesSurviveSettingsAndTimeZoneChanges() throws {
        try withStore { store, _ in
            var saved = SavedData(); saved.settings.postponeLimit = 0
            saved.snapshot.shortElapsed = saved.settings.shortInterval + 100
            var reminder = Reminder(kind: .short, target: 30)
            reminder.elapsed = 21; reminder.postponements = 2
            saved.snapshot.deferredReminder = reminder; saved.snapshot.deferredRemaining = 0
            var record = Record(date: Date(), kind: nil, outcome: .usage, seconds: 5)
            record.day = "2024-02-29"; record.timeZoneOffset = -28800
            saved.records = [record]
            try store.save(saved); let loaded = store.load()
            #expect(store.loadErrorKey == nil)
            #expect(loaded.snapshot.shortElapsed == saved.snapshot.shortElapsed)
            #expect(loaded.snapshot.deferredReminder == reminder)
            #expect(loaded.records.first?.day == record.day)
        }
    }
}
