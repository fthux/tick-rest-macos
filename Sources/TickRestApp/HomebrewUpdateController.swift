import AppKit
import Combine
import TickRestCore

enum HomebrewUpdateConfiguration {
    // Select at compile time so a Release binary never checks the test feed.
#if DEBUG
    static let feedURL = URL(string: "https://raw.githubusercontent.com/fthux/test-repo/refs/heads/master/updates/homebrew-update.json")!
    static let preferencesPrefix = "homebrewUpdate.debug."
#else
    static let feedURL = URL(string: "https://raw.githubusercontent.com/fthux/tick-rest-macos/master/updates/homebrew-update.json")!
    static let preferencesPrefix = "homebrewUpdate.release."
#endif
    static let upgradeCommand = "brew update && brew upgrade fthux/tap/tickrest"
}

struct HomebrewUpdateClient {
    var session: URLSession = .shared
    var feedURL = HomebrewUpdateConfiguration.feedURL

    func fetch() async throws -> HomebrewUpdateManifest {
        var request = URLRequest(url: feedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw HomebrewUpdateError.network }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw HomebrewUpdateError.unavailable
        }
        guard data.count <= 64 * 1024 else { throw HomebrewUpdateError.invalidManifest }
        let manifest: HomebrewUpdateManifest
        do { manifest = try JSONDecoder().decode(HomebrewUpdateManifest.self, from: data) }
        catch { throw HomebrewUpdateError.invalidManifest }
        try manifest.validate()
        return manifest
    }
}

final class HomebrewUpdateController: ObservableObject {
    enum Status: Equatable {
        case idle, checking, upToDate, available, incompatible, failed(String)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var manifest: HomebrewUpdateManifest?
    @Published private(set) var automaticChecks: Bool
    @Published private(set) var lastChecked: Date?
    @Published private(set) var showsUpdateWindow = false

    let currentVersion: String
    private let systemVersion: String
    private let defaults: UserDefaults
    private let client: HomebrewUpdateClient
    private let now: () -> Date
    private var timer: AnyCancellable?
    private var task: Task<Void, Never>?
    private var checkGeneration = 0
    private var statusBeforeCheck: Status = .idle
    private var started = false
    private static let prefix = HomebrewUpdateConfiguration.preferencesPrefix

    init(currentVersion: String = AppBuildInfo.current.version,
         systemVersion: String? = nil, defaults: UserDefaults = .standard,
         client: HomebrewUpdateClient = HomebrewUpdateClient(), now: @escaping () -> Date = Date.init) {
        self.currentVersion = currentVersion
        let os = ProcessInfo.processInfo.operatingSystemVersion
        self.systemVersion = systemVersion ?? "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        self.defaults = defaults; self.client = client; self.now = now
        automaticChecks = defaults.object(forKey: Self.prefix + "automatic") as? Bool ?? true
        lastChecked = defaults.object(forKey: Self.prefix + "lastSuccess") as? Date
        // Only restore automatic reminders when the user has opted in.
        if automaticChecks, let data = defaults.data(forKey: Self.prefix + "manifest"),
           let cached = try? JSONDecoder().decode(HomebrewUpdateManifest.self, from: data),
           (try? cached.isNewer(than: currentVersion)) == true {
            manifest = cached
            status = cached.supports(systemVersion: self.systemVersion) ? .available : .incompatible
        }
    }

    deinit { timer?.cancel(); task?.cancel() }

    var isChecking: Bool { status == .checking }
    var availableUpdate: HomebrewUpdateManifest? {
        guard let manifest, (try? manifest.isNewer(than: currentVersion)) == true else { return nil }
        return manifest
    }
    var canUpgrade: Bool { availableUpdate?.supports(systemVersion: systemVersion) == true }
    var releaseHistoryURL: URL { manifest?.historyURL ?? HomebrewUpdateManifest.defaultReleaseHistoryURL }

    @MainActor func checkInteractively() {
        requestCheck()
        showsUpdateWindow = true
    }

    @MainActor func showAvailableUpdate() {
        guard availableUpdate != nil else { checkInteractively(); return }
        showsUpdateWindow = true
    }

    @MainActor func dismissUpdateWindow() {
        showsUpdateWindow = false
        cancelCheck()
    }

    var statusText: String {
        switch status {
        case .idle: return L10n.text("update.idle")
        case .checking: return L10n.text("update.checking")
        case .upToDate: return L10n.text("update.up_to_date", currentVersion)
        case .available: return L10n.text("update.available", manifest?.version ?? "")
        case .incompatible: return L10n.text("update.requires_system", manifest?.version ?? "", manifest?.minimumSystemVersion ?? "")
        case .failed(let key): return L10n.text(key)
        }
    }

    var menuTitle: String {
        if isChecking { return L10n.text("update.checking") }
        if let update = availableUpdate { return L10n.text("update.menu_available", update.version) }
        return L10n.text("update.check")
    }

    @MainActor func start() {
        guard !started else { return }
        started = true
        checkAutomaticallyIfDue()
        timer = Timer.publish(every: 900, tolerance: 60, on: .main, in: .common)
            .autoconnect().sink { [weak self] _ in self?.checkAutomaticallyIfDue() }
    }

    @MainActor func stop() {
        started = false
        showsUpdateWindow = false
        timer?.cancel(); timer = nil
        cancelCheck()
    }

    @MainActor private func cancelCheck() {
        checkGeneration += 1
        task?.cancel(); task = nil
        if isChecking { status = automaticChecks ? statusBeforeCheck : .idle }
    }

    @MainActor func setAutomaticChecks(_ enabled: Bool) {
        automaticChecks = enabled
        defaults.set(enabled, forKey: Self.prefix + "automatic")
        if !enabled {
            manifest = nil
            if !isChecking { status = .idle; showsUpdateWindow = false }
        }
        if enabled && started { checkAutomaticallyIfDue() }
    }

    @MainActor func checkAutomaticallyIfDue() {
        guard automaticChecks, !isChecking else { return }
        let date = now()
        // Failed requests retry at most hourly; successful checks are daily.
        if let lastChecked, date.timeIntervalSince(lastChecked) >= 0,
           date.timeIntervalSince(lastChecked) < 86400 { return }
        if let attempt = defaults.object(forKey: Self.prefix + "lastAttempt") as? Date,
           date.timeIntervalSince(attempt) >= 0, date.timeIntervalSince(attempt) < 3600 { return }
        requestCheck(userInitiated: false)
    }

    @MainActor func requestCheck(userInitiated: Bool = true) {
        guard !isChecking, task == nil else { return }
        let generation = checkGeneration
        task = Task { [weak self] in
            guard let self else { return }
            await self.check(userInitiated: userInitiated)
            if self.checkGeneration == generation { self.task = nil }
        }
    }

    @MainActor func check(userInitiated: Bool = true) async {
        guard !Task.isCancelled, !isChecking, userInitiated || automaticChecks else { return }
        let generation = checkGeneration
        let previousStatus = status
        statusBeforeCheck = previousStatus
        status = .checking
        defaults.set(now(), forKey: Self.prefix + "lastAttempt")
        do {
            try Task.checkCancellation()
            guard UpdateVersion(currentVersion) != nil else { throw HomebrewUpdateError.invalidCurrentVersion }
            let update = try await client.fetch()
            try Task.checkCancellation()
            guard generation == checkGeneration else { return }
            // A background request may finish after the user turns off checks.
            guard userInitiated || automaticChecks else {
                status = .idle; showsUpdateWindow = false; return
            }
            let newer = try update.isNewer(than: currentVersion)
            manifest = update
            lastChecked = now()
            defaults.set(lastChecked, forKey: Self.prefix + "lastSuccess")
            defaults.set(try JSONEncoder().encode(update), forKey: Self.prefix + "manifest")
            status = newer ? (canUpgrade ? .available : .incompatible) : .upToDate
        } catch is CancellationError {
            guard generation == checkGeneration else { return }
            status = !userInitiated && !automaticChecks ? .idle : previousStatus
        } catch {
            guard generation == checkGeneration else { return }
            // Background failures never open windows or erase a known update reminder.
            status = userInitiated ? .failed(Self.messageKey(for: error)) : (automaticChecks ? previousStatus : .idle)
        }
        if !userInitiated && !automaticChecks { showsUpdateWindow = false }
    }

    private static func messageKey(for error: Error) -> String {
        switch error as? HomebrewUpdateError {
        case .invalidManifest, .unsupportedSchema: return "update.error_manifest"
        case .invalidCurrentVersion: return "update.error_version"
        case .unavailable: return "update.error_unavailable"
        default: return "update.error_network"
        }
    }
}
