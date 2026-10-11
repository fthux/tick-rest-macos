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
                  result.snapshot.pendingPlan?.validationErrorKey == nil else {
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
               last.reminderID == item.reminderID, last.planID == item.planID, last.timingModel == item.timingModel, last.basePlanID == item.basePlanID, item.date.timeIntervalSince(last.date) <= 10 {
                records[records.count - 1].seconds += item.seconds
                records[records.count - 1].date = item.date
            } else { records.append(item) }
        }
        let oldest = now.addingTimeInterval(-recordRetention)
        records.removeAll { $0.date < oldest }
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
