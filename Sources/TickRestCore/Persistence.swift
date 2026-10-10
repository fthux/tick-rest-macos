import Foundation

public struct SavedData: Codable {
    public var version = 1
    public var settings = Settings()
    public var records: [Record] = []
    public var snapshot = Snapshot()
    public init() {}
}

public final class DataStore {
    public let url: URL
    public private(set) var loadError: String?
    public init(url: URL? = nil) {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.url = url ?? directory.appendingPathComponent(AppIdentity.dataDirectory, isDirectory: true).appendingPathComponent("state.json")
    }
    public func load() -> SavedData {
        guard FileManager.default.fileExists(atPath: url.path) else { return SavedData() }
        do {
            let result = try JSONDecoder().decode(SavedData.self, from: Data(contentsOf: url))
            guard result.version == 1, result.settings.validationError == nil else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return result
        } catch {
            loadError = L10n.text("error.load")
            let backup = url.deletingLastPathComponent().appendingPathComponent("state-damaged-\(Int(Date().timeIntervalSince1970)).json")
            // If preserving the file fails, saving must not overwrite the only copy.
            do { try FileManager.default.copyItem(at: url, to: backup) }
            catch { loadError = L10n.text("error.load_preserve"); canWrite = false }
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
               last.reminderID == item.reminderID, item.date.timeIntervalSince(last.date) <= 10 {
                records[records.count - 1].seconds += item.seconds
                records[records.count - 1].date = item.date
            } else { records.append(item) }
        }
        let oldest = now.addingTimeInterval(-90 * 86400)
        records.removeAll { $0.date < oldest }
    }
}

public struct TodaySummary {
    public var usage: Double = 0
    public var rest: Double = 0
    public var natural: Double = 0
    public var completed = 0
    public var skipped = 0
    public var ended = 0
    public init(records: [Record], now: Date = Date()) {
        for item in records where item.day == Record.dayKey(now) {
            switch item.outcome {
            case .usage: if item.reminderID == nil { usage += item.seconds } else { rest += item.seconds }
            case .completed: completed += 1
            case .skipped: skipped += 1
            case .ended: ended += 1
            case .natural: natural += item.seconds
            default: break
            }
        }
    }
}
