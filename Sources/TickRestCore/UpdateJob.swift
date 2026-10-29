import Foundation

public struct UpdateJob: Codable {
    public let id: UUID
    public let installation: HomebrewInstallation
    public let required: UpdateRelease
    public let parentPID: Int32
    public let language: String
    public let automatic: Bool
    public let created: Date
    public init(installation: HomebrewInstallation, required: UpdateRelease, parentPID: Int32,
                language: String, automatic: Bool) {
        id = UUID(); self.installation = installation; self.required = required; self.parentPID = parentPID
        self.language = language; self.automatic = automatic; created = Date()
    }
}

public struct UpdateJobState: Codable, Equatable {
    public enum Phase: String, Codable {
        case preparing, refreshing, downloading, waiting, installing, verifying, relaunching, completed, failed, cancelled
        public var terminal: Bool { [.completed, .failed, .cancelled].contains(self) }
        public var canCancel: Bool { [.preparing, .refreshing, .downloading, .waiting].contains(self) }
    }
    public let phase: Phase
    public let failure: HomebrewUpgradeFailure?
    public init(_ phase: Phase, failure: HomebrewUpgradeFailure? = nil) { self.phase = phase; self.failure = failure }
    public var message: String {
        let key = "update.stage." + phase.rawValue
        return failure?.errorDescription ?? L10n.text(key)
    }
}

/// All control files live in a private per-user directory, outside the app being replaced.
public struct UpdateJobStore {
    public static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(AppIdentity.dataDirectory).appendingPathComponent("Updates", isDirectory: true)
    }
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    public func file(_ name: String) -> URL { directory.appendingPathComponent(name) }
    public static func create(_ job: UpdateJob, root: URL = Self.root) throws -> Self {
        let directory = root.appendingPathComponent(job.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let store = Self(directory: directory)
        try store.write(job, named: "job.json")
        try store.write(UpdateJobState(.preparing), named: "state.json")
        return store
    }
    public func validatedJob(root: URL = Self.root) throws -> UpdateJob {
        let resolved = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.deletingLastPathComponent() == root.standardizedFileURL.resolvingSymlinksInPath(),
              UUID(uuidString: resolved.lastPathComponent) != nil else { throw HomebrewUpgradeFailure.invalidJob }
        let attributes = try FileManager.default.attributesOfItem(atPath: resolved.path)
        guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o077 == 0 else {
            throw HomebrewUpgradeFailure.invalidJob
        }
        let job: UpdateJob = try read("job.json")
        guard job.id.uuidString == resolved.lastPathComponent, Date().timeIntervalSince(job.created) < 86400,
              job.created.timeIntervalSinceNow < 60, job.parentPID > 1,
              UpdateVersion(job.required.version) != nil,
              job.required.build == nil || UpdateVersion(job.required.build!) != nil else { throw HomebrewUpgradeFailure.invalidJob }
        try job.installation.validate()
        return job
    }
    public func write<T: Encodable>(_ value: T, named name: String) throws {
        let url = file(name)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func read<T: Decodable>(_ name: String) throws -> T {
        let data = try Data(contentsOf: file(name))
        guard data.count < 128 * 1024 else { throw HomebrewUpgradeFailure.invalidJob }
        return try JSONDecoder().decode(T.self, from: data)
    }
    public func signal(_ name: String) throws { try write(true, named: name) }
    public func hasSignal(_ name: String) -> Bool { (try? read(name) as Bool) == true }
    public var state: UpdateJobState? { try? read("state.json") }
    public func appendLog(_ text: String) {
        let url = file("update.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        // Bound disk use for verbose or repeatedly failing external commands.
        guard let offset = try? handle.seekToEnd(), offset < 4 * 1024 * 1024 else { return }
        try? handle.write(contentsOf: Data(text.utf8.prefix(64 * 1024)))
    }
}
