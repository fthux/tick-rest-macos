import Foundation

public struct SavedData: Codable {
    public var version = 2
    public var settings = Settings()
    public var records: [Record] = []
    public var snapshot = Snapshot()
    public init() {}
}

public final class DataStore {
    public static let recordRetention: TimeInterval = 90 * 86400
    public let url: URL
    public private(set) var loadErrorKey: String?
    public var loadError: String? { loadErrorKey.map { L10n.text($0) } }
    public init(url: URL? = nil) {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.url = url ?? directory.appendingPathComponent(AppIdentity.dataDirectory, isDirectory: true).appendingPathComponent("state.json")
    }
    public func load() -> SavedData {
        guard FileManager.default.fileExists(atPath: url.path) else { return SavedData() }
        do {
            var result = try JSONDecoder().decode(SavedData.self, from: Data(contentsOf: url))
            guard (1...2).contains(result.version), result.settings.validationError == nil,
                  Self.validSnapshot(result.snapshot, settings: result.settings),
                  result.records.allSatisfy(Self.validRecord),
                  Set(result.records.map(\.id)).count == result.records.count else {
                throw CocoaError(.fileReadCorruptFile)
            }
            if result.version == 1 {
                let backup = url.deletingLastPathComponent().appendingPathComponent("state-v1-backup.json")
                if !FileManager.default.fileExists(atPath: backup.path) { try FileManager.default.copyItem(at: url, to: backup) }
                result.version = 2
            }
            return result
        } catch {
            loadErrorKey = "error.load"
            let backup = url.deletingLastPathComponent().appendingPathComponent("state-damaged-\(Int(Date().timeIntervalSince1970)).json")
            // If preserving the file fails, saving must not overwrite the only copy.
            do { try FileManager.default.copyItem(at: url, to: backup) }
            catch { loadErrorKey = "error.load_preserve"; canWrite = false }
            return SavedData()
        }
    }
    private var canWrite = true
    private static func validSnapshot(_ snapshot: Snapshot, settings: Settings) -> Bool {
        let durations = [snapshot.shortElapsed, snapshot.longElapsed,
                         snapshot.shortCooldown, snapshot.longCooldown]
        guard durations.allSatisfy({ $0.isFinite && $0 >= 0 }),
              snapshot.savedAt.timeIntervalSinceReferenceDate.isFinite,
              snapshot.activeReminder == nil || snapshot.deferredReminder == nil,
              (snapshot.deferredReminder == nil) == (snapshot.deferredRemaining == nil),
              snapshot.completedRounds.map({ (0...12).contains($0) }) ?? true else { return false }
        if let delay = snapshot.deferredRemaining, !delay.isFinite || delay < 0 { return false }
        if case .until(let date) = snapshot.pause, !date.timeIntervalSinceReferenceDate.isFinite { return false }
        if let kind = snapshot.roundRestKind,
           settings.timingModel != .rounds || !settings.enabled(kind) { return false }
        for reminder in [snapshot.activeReminder, snapshot.deferredReminder].compactMap({ $0 }) {
            guard settings.enabled(reminder.kind), reminder.target.isFinite, reminder.target > 0,
                  reminder.elapsed.isFinite, (0...reminder.target).contains(reminder.elapsed),
                  (0...10).contains(reminder.postponements), (0..<5).contains(reminder.ideaIndex) else { return false }
            // Targets and budgets may predate an edit to duration or postpone limit.
            // Legacy reminders also have no plan metadata.
        }
        if let pending = snapshot.pendingPlan {
            var future = settings; future.restPlan = pending
            guard future.validationErrorKey == nil else { return false }
        }
        return true
    }
    private static func validRecord(_ record: Record) -> Bool {
        guard record.seconds.isFinite, record.seconds >= 0,
              record.date.timeIntervalSinceReferenceDate.isFinite else { return false }
        // Saved day keys retain their original calendar date across time zones;
        // validate the date itself without deriving it from today's time zone.
        let bytes = Array(record.day.utf8)
        guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45,
              bytes.enumerated().allSatisfy({ [4, 7].contains($0.offset) || (48...57).contains($0.element) }) else { return false }
        let parts = record.day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...9999).contains(parts[0]) else { return false }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return false }
        return Record.dayKey(date, calendar: calendar) == record.day
    }
    public func save(_ data: SavedData) throws {
        guard canWrite else { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(data).write(to: url, options: .atomic)
    }
    public static func append(_ additions: [Record], to records: inout [Record], now: Date) {
        for item in additions {
            if item.outcome == .usage, let last = records.last,
               last.outcome == .usage, last.day == item.day, last.kind == item.kind,
               last.reminderID == item.reminderID, last.planID == item.planID,
               last.timingModel == item.timingModel, last.basePlanID == item.basePlanID,
               item.date >= last.date,
               abs(item.date.timeIntervalSince(last.date) - item.seconds) < 0.002 {
                records[records.count - 1].seconds += item.seconds
                records[records.count - 1].date = item.date
            } else { records.append(item) }
        }
        let oldest = now.addingTimeInterval(-recordRetention)
        records.removeAll { $0.date < oldest }
        for index in records.indices where records[index].outcome == .usage || records[index].outcome == .natural {
            // Duration records end at `date`; trim the part before the cutoff.
            // Point events at the exact cutoff retain their identity and counts.
            records[index].seconds = min(records[index].seconds, max(0, records[index].date.timeIntervalSince(oldest)))
        }
    }
}

public struct StatisticsSummary {
    public var usage: Double = 0
    public var rest: Double = 0
    public var natural: Double = 0
    public var completed = 0
    public var skipped = 0
    public var ended = 0
    public var focusCompleted = 0
    public private(set) var hasRecords = false
    public init(records: [Record], range: StatisticsDateRange) {
        for item in records where range.contains(day: item.day) {
            hasRecords = true
            switch item.outcome {
            case .usage: if item.reminderID == nil { usage += item.seconds } else { rest += item.seconds }
            case .completed: completed += 1
            case .skipped: skipped += 1
            case .ended: ended += 1
            case .focusCompleted: focusCompleted += 1
            case .natural: natural += item.seconds
            default: break
            }
        }
    }
    public init(records: [Record], now: Date = Date()) {
        self.init(records: records, range: StatisticsDateRange(start: now, end: now))
    }
}

// Keep the existing single-day API for clients and reminder tests.
public typealias TodaySummary = StatisticsSummary
