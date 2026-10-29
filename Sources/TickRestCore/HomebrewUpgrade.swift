import Foundation
import Darwin

public enum AppDistributionChannel: String, Codable {
    case stable, dev
    public var package: String { "fthux/tap/" + (self == .dev ? "tickrest-dev" : "tickrest") }
    public var repository: String { self == .dev ? "tick-rest-macos-dev" : "tick-rest-macos" }
    public var caskToken: String { self == .dev ? "tickrest-dev" : "tickrest" }
    public var caskURL: URL {
        URL(string: "https://raw.githubusercontent.com/fthux/homebrew-tap/HEAD/Casks/\(caskToken).rb")!
    }
    public var caskAPIURL: URL {
        URL(string: "https://api.github.com/repos/fthux/homebrew-tap/contents/Casks/\(caskToken).rb")!
    }
    public var releaseHistoryURL: URL {
        self == .dev ? URL(string: "https://github.com/fthux/\(repository)/releases")! : HomebrewUpdateManifest.defaultReleaseHistoryURL
    }
}

public struct UpdateRelease: Codable, Equatable, Comparable {
    public let version: String
    public let build: String?
    public init(version: String, build: String? = nil) { self.version = version; self.build = build }
    public init?(caskVersion: String) {
        let parts = caskVersion.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard (1...2).contains(parts.count), UpdateVersion(parts[0]) != nil,
              parts.count == 1 || UpdateVersion(parts[1]) != nil else { return nil }
        self.init(version: parts[0], build: parts.count == 2 ? parts[1] : nil)
    }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        guard let left = UpdateVersion(lhs.version), let right = UpdateVersion(rhs.version) else { return false }
        if left != right { return left < right }
        return (UpdateVersion(lhs.build ?? "0") ?? UpdateVersion("0")!) <
            (UpdateVersion(rhs.build ?? "0") ?? UpdateVersion("0")!)
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        UpdateVersion(lhs.version) == UpdateVersion(rhs.version) && UpdateVersion(lhs.build ?? "0") == UpdateVersion(rhs.build ?? "0")
    }
    public func meets(_ required: Self) -> Bool {
        guard let version = UpdateVersion(version), let minimum = UpdateVersion(required.version) else { return false }
        if version != minimum { return version > minimum }
        guard let build = required.build else { return true }
        guard let actual = UpdateVersion(self.build ?? "0"), let minimumBuild = UpdateVersion(build) else { return false }
        return actual >= minimumBuild
    }
    public var identifier: String { version + "," + (build ?? "0") }
}

public enum HomebrewUpgradeFailure: String, Error, LocalizedError, Codable {
    case homebrewMissing, notManaged, ambiguous, architecture, notReady, metadataChanged
    case command, save, permissions, helperMissing, timeout, cancelled, invalidJob, verification, launch, parentGone
    public var errorDescription: String? {
        let key = "update.failure." + rawValue
        return L10n.text(key)
    }
}

public struct BrewCommandResult {
    public let status: Int32
    public let output: Data
    public init(status: Int32, output: Data = Data()) { self.status = status; self.output = output }
}

public protocol BrewCommandRunning: AnyObject {
    func run(executable: URL, arguments: [String], environment: [String: String], timeout: TimeInterval) async throws -> BrewCommandResult
    func cancel()
}

/// Executes literal arguments in a separate process group, so cancelling also stops curl/git.
/// Nonblocking pipes keep a descendant holding stdout open from hanging the updater forever.
public final class BrewProcessRunner: BrewCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public var onOutput: ((String) -> Void)?
    public init() {}
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    public func run(executable: URL, arguments: [String], environment: [String: String], timeout: TimeInterval) async throws -> BrewCommandResult {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    do { continuation.resume(returning: try execute(executable, arguments, environment, timeout)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { self.cancel() })
    }

    private func execute(_ executable: URL, _ arguments: [String], _ environment: [String: String], _ timeout: TimeInterval) throws -> BrewCommandResult {
        guard !isCancelled else { throw HomebrewUpgradeFailure.cancelled }
        let stdout = Pipe(), stderr = Pipe()
        let readers = [stdout.fileHandleForReading, stderr.fileHandleForReading]
        let writers = [stdout.fileHandleForWriting, stderr.fileHandleForWriting]
        defer { for handle in readers + writers { try? handle.close() } }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        for (index, handle) in writers.enumerated() {
            posix_spawn_file_actions_adddup2(&actions, handle.fileDescriptor, index == 0 ? STDOUT_FILENO : STDERR_FILENO)
        }
        for handle in readers + writers { posix_spawn_file_actions_addclose(&actions, handle.fileDescriptor) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.sorted { $0.key < $1.key }.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        let result = argv.withUnsafeBufferPointer { args in
            envp.withUnsafeBufferPointer { env in
                posix_spawn(&pid, executable.path, &actions, &attributes,
                            UnsafeMutablePointer(mutating: args.baseAddress!), UnsafeMutablePointer(mutating: env.baseAddress!))
            }
        }
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(result)) }
        for handle in writers { try? handle.close() }
        for handle in readers { _ = fcntl(handle.fileDescriptor, F_SETFL, O_NONBLOCK) }
        let started = ProcessInfo.processInfo.systemUptime
        var stoppedAt: TimeInterval?, failure: HomebrewUpgradeFailure?
        var status: Int32 = 0, exited = false, closed = [false, false], output = Data()
        var buffer = [UInt8](repeating: 0, count: 16384)
        while !exited || closed.contains(false) {
            let now = ProcessInfo.processInfo.systemUptime
            if failure == nil, isCancelled || now - started >= timeout {
                failure = isCancelled ? .cancelled : .timeout
                stoppedAt = now
                kill(-pid, SIGTERM)
            }
            if let stoppedAt, now - stoppedAt >= 1 {
                kill(-pid, SIGKILL)
                // Descendants can detach from the group; never wait on their inherited pipe.
                closed = [true, true]
            }
            for index in readers.indices where !closed[index] {
                // Bound each pass as well as retained JSON, even with continuously noisy stderr.
                for _ in 0..<32 {
                    let count = Darwin.read(readers[index].fileDescriptor, &buffer, buffer.count)
                    if count == 0 { closed[index] = true; break }
                    if count < 0 {
                        if errno != EAGAIN && errno != EINTR { closed[index] = true }
                        break
                    }
                    let chunk = Data(buffer.prefix(count))
                    if index == 0 { output.append(chunk.prefix(max(0, 1024 * 1024 - output.count))) }
                    onOutput?(String(decoding: chunk, as: UTF8.self))
                }
            }
            if !exited {
                let waited = waitpid(pid, &status, WNOHANG)
                if waited == pid || (waited < 0 && errno == ECHILD) { exited = true }
            }
            if !exited || closed.contains(false) { usleep(20_000) }
        }
        if let failure { throw failure }
        let signal = status & 0x7f
        return BrewCommandResult(status: signal == 0 ? (status >> 8) & 0xff : 128 + signal, output: output)
    }
}

public struct BrewCaskSnapshot: Equatable {
    public let release: UpdateRelease
    public let installed: UpdateRelease
    public let target: URL
    public let fingerprint: String

    public init(data: Data, channel: AppDistributionChannel, appURL: URL, appDirectory: URL) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let casks = root["casks"] as? [[String: Any]], casks.count == 1, let cask = casks.first,
              cask["tap"] as? String == "fthux/tap",
              cask["token"] as? String == channel.package.components(separatedBy: "/").last,
              let version = cask["version"] as? String, let release = UpdateRelease(caskVersion: version),
              let installedString = cask["installed"] as? String,
              let installed = UpdateRelease(caskVersion: installedString),
              cask["disabled"] as? Bool != true, cask["pinned"] as? Bool != true,
              let urlString = cask["url"] as? String, let url = URLComponents(string: urlString),
              url.scheme == "https", url.host == "github.com", url.user == nil, url.password == nil, url.port == nil,
              url.path.hasPrefix("/fthux/\(channel.repository)/releases/download/"),
              let sha = cask["sha256"] as? String, sha.count == 64, sha.allSatisfy({ $0.isHexDigit && $0.isASCII }),
              let artifacts = cask["artifacts"] as? [[String: Any]] else { throw HomebrewUpgradeFailure.notManaged }
        let apps = artifacts.filter { $0["app"] != nil }
        guard apps.count == 1, let artifact = apps.first, let app = artifact["app"] as? [Any],
              let sourceName = app.first as? String, sourceName.hasSuffix(".app") else { throw HomebrewUpgradeFailure.notManaged }
        guard let installedTarget = artifact["target"] as? String, installedTarget.hasPrefix("/") else {
            throw HomebrewUpgradeFailure.notManaged
        }
        let target = URL(fileURLWithPath: installedTarget).standardizedFileURL.resolvingSymlinksInPath()
        // Use Homebrew's recorded target, never infer ownership from an app's filename.
        guard target == appURL.standardizedFileURL.resolvingSymlinksInPath() else { throw HomebrewUpgradeFailure.notManaged }
        self.release = release; self.installed = installed; self.target = target
        fingerprint = version + "|" + urlString + "|" + sha + "|" + sourceName + "|" + target.path
    }
}

public struct HomebrewInstallation: Codable, Equatable {
    public let brew: URL
    public let channel: AppDistributionChannel
    public let app: URL
    public let architecture: String
    public let current: UpdateRelease
    public init(brew: URL, channel: AppDistributionChannel, app: URL, architecture: String, current: UpdateRelease) {
        self.brew = brew; self.channel = channel; self.app = app; self.architecture = architecture; self.current = current
    }
    public var appDirectory: URL { app.deletingLastPathComponent() }
    public func environment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var result: [String: String] = [:]
        // Preserve network configuration without importing arbitrary Homebrew execution switches.
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "http_proxy", "https_proxy", "all_proxy", "no_proxy",
                    "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "SSL_CERT_FILE", "CURL_CA_BUNDLE", "SSH_AUTH_SOCK"] {
            result[key] = base[key]
        }
        result["PATH"] = brew.deletingLastPathComponent().path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        result["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        result["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
        result["HOMEBREW_NO_ANALYTICS"] = "1"
        result["HOMEBREW_NO_ENV_HINTS"] = "1"
        result["HOMEBREW_NO_COLOR"] = "1"
        result["NONINTERACTIVE"] = "1"
        if channel == .dev { result["HOMEBREW_TICKREST_DEV_ARCH"] = architecture }
        return result
    }
    public static let brewCandidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].map { URL(fileURLWithPath: $0) }
    public func validate() throws {
        guard Self.brewCandidates.contains(brew), ["arm64", "x86_64", "universal"].contains(architecture),
              app.pathExtension == "app", app.isFileURL, UpdateVersion(current.version) != nil,
              current.build == nil || UpdateVersion(current.build!) != nil else {
            throw HomebrewUpgradeFailure.invalidJob
        }
    }
}

/// The same engine runs in the independent helper and in isolated integration tests.
public final class HomebrewUpgradeEngine {
    private let runner: BrewCommandRunning
    public init(runner: BrewCommandRunning) { self.runner = runner }
    public func snapshot(_ installation: HomebrewInstallation) async throws -> BrewCaskSnapshot {
        let result = try await command(installation, ["info", "--json=v2", "--cask", installation.channel.package], timeout: 60)
        return try BrewCaskSnapshot(data: result.output, channel: installation.channel, appURL: installation.app,
                                    appDirectory: installation.appDirectory)
    }
    public func prepare(_ installation: HomebrewInstallation, required: UpdateRelease,
                        stage: @MainActor (String) throws -> Void) async throws -> BrewCaskSnapshot {
        try await stage("update.stage.preparing")
        let original = try await snapshot(installation)
        guard UpdateVersion(original.installed.version) == UpdateVersion(installation.current.version),
              original.installed.build == nil || original.installed == installation.current else {
            throw HomebrewUpgradeFailure.notManaged
        }
        try await stage("update.stage.refreshing")
        _ = try await command(installation, ["update"], timeout: 600)
        let target = try await snapshot(installation)
        guard target.release.meets(required), installation.current < target.release else { throw HomebrewUpgradeFailure.notReady }
        try await stage("update.stage.downloading")
        _ = try await command(installation, ["fetch", "--cask", installation.channel.package], timeout: 1800)
        let downloaded = try await snapshot(installation)
        guard target == downloaded else { throw HomebrewUpgradeFailure.metadataChanged }
        return target
    }
    public func install(_ installation: HomebrewInstallation, prepared: BrewCaskSnapshot,
                        stage: @MainActor (String) throws -> Void) async throws {
        guard try await snapshot(installation) == prepared else { throw HomebrewUpgradeFailure.metadataChanged }
        try await stage("update.stage.installing")
        _ = try await command(installation, ["upgrade", "--cask", installation.channel.package,
                                           "--appdir=" + installation.appDirectory.path], timeout: 900)
        try await stage("update.stage.verifying")
        let installed = try await snapshot(installation)
        guard installed.installed.meets(prepared.release) else { throw HomebrewUpgradeFailure.verification }
        try Self.verifyApplication(installation.app, required: prepared.release, architecture: installation.architecture,
                                   channel: installation.channel)
    }
    @discardableResult private func command(_ installation: HomebrewInstallation, _ arguments: [String], timeout: TimeInterval) async throws -> BrewCommandResult {
        let result = try await runner.run(executable: installation.brew, arguments: arguments,
                                          environment: installation.environment(), timeout: timeout)
        guard result.status == 0 else { throw HomebrewUpgradeFailure.command }
        return result
    }
    public static func verifyApplication(_ url: URL, required: UpdateRelease, architecture: String,
                                         channel: AppDistributionChannel) throws {
        let data = try Data(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == AppIdentity.bundleIdentifier,
              info["AppBuildArchitecture"] as? String == architecture,
              (info["AppDistributionChannel"] as? String ?? "stable") == channel.rawValue,
              let version = info["CFBundleShortVersionString"] as? String,
              UpdateRelease(version: version, build: info["CFBundleVersion"] as? String).meets(required),
              let executable = info["CFBundleExecutable"] as? String, !executable.contains("/"),
              FileManager.default.isExecutableFile(atPath: url.appendingPathComponent("Contents/MacOS/" + executable).path) else {
            throw HomebrewUpgradeFailure.verification
        }
    }
}
