import AppKit
import Combine
import TickRestCore

enum HomebrewUpdateConfiguration {
    static let channel = AppDistributionChannel(rawValue: Bundle.main.object(forInfoDictionaryKey: "AppDistributionChannel") as? String ?? "stable") ?? .stable
    static let caskURL = channel.caskURL
#if DEBUG
    static let preferencesPrefix = "homebrewUpdate.debug." + (channel == .dev ? "dev." : "")
#else
    static let preferencesPrefix = "homebrewUpdate.release." + (channel == .dev ? "dev." : "")
#endif
}

final class HomebrewUpdateController: ObservableObject {
    enum Status: Equatable {
        case idle, checking, upToDate, available, incompatible, failed(String)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var manifest: HomebrewUpdateManifest?
    @Published private(set) var automaticInstallation: Bool
    @Published private(set) var lastChecked: Date?
    @Published private(set) var showsUpdateWindow = false

    let currentVersion: String
    let currentBuild: String?
    let installer = HomebrewUpgradeCoordinator()
    private var installerSubscription: AnyCancellable?
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
         currentBuild: String? = AppBuildInfo.current.buildNumber,
         systemVersion: String? = nil, defaults: UserDefaults = .standard,
         client: HomebrewUpdateClient = HomebrewUpdateClient(), now: @escaping () -> Date = Date.init) {
        self.currentVersion = currentVersion
        self.currentBuild = currentBuild
        let os = ProcessInfo.processInfo.operatingSystemVersion
        self.systemVersion = systemVersion ?? "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        self.defaults = defaults; self.client = client; self.now = now
        // Migrate only an existing installation opt-in; checking alone never grants install consent.
        automaticInstallation = defaults.object(forKey: Self.prefix + "automaticUpdates") as? Bool
            ?? (defaults.bool(forKey: Self.prefix + "automaticInstall") && (defaults.object(forKey: Self.prefix + "automatic") as? Bool != false))
        lastChecked = defaults.object(forKey: Self.prefix + "caskLastSuccess") as? Date
        // Only restore automatic reminders when the user has opted in.
        if automaticInstallation, let data = defaults.data(forKey: Self.prefix + "caskManifest"),
           let cached = try? JSONDecoder().decode(HomebrewUpdateManifest.self, from: data),
           (cached.channel ?? .stable) == client.channel,
           (try? cached.isNewer(than: currentVersion, currentBuild: currentBuild)) == true {
            manifest = cached
            status = cached.supports(systemVersion: self.systemVersion) ? .available : .incompatible
        }
        installerSubscription = installer.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    deinit { timer?.cancel(); task?.cancel() }

    var isChecking: Bool { status == .checking }
    var availableUpdate: HomebrewUpdateManifest? {
        guard let manifest, (try? manifest.isNewer(than: currentVersion, currentBuild: currentBuild)) == true else { return nil }
        return manifest
    }
    var canUpgrade: Bool { availableUpdate?.supports(systemVersion: systemVersion) == true }
    var availableVersionText: String {
        guard let update = availableUpdate else { return "" }
        if UpdateVersion(update.version) == UpdateVersion(currentVersion), let build = update.buildNumber {
            return update.version + " (" + build + ")"
        }
        return update.version
    }
    var currentVersionText: String {
        if let update = availableUpdate, UpdateVersion(update.version) == UpdateVersion(currentVersion),
           update.buildNumber != nil, let currentBuild { return currentVersion + " (" + currentBuild + ")" }
        return currentVersion
    }
    var shouldRemind: Bool {
        guard let update = availableUpdate,
              defaults.string(forKey: Self.prefix + "skipped") != update.release.identifier else { return false }
        if let until = defaults.object(forKey: Self.prefix + "remindAfter") as? Date, until > now() { return false }
        return true
    }
    var releaseHistoryURL: URL { manifest?.historyURL ?? client.channel.releaseHistoryURL }

    @MainActor func checkInteractively() {
        if installer.isActive { installer.showProgress(); return }
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
        if installer.isActive, let state = installer.state { return state.message }
        switch status {
        case .idle: return L10n.text("update.idle")
        case .checking: return L10n.text("update.checking")
        case .upToDate: return L10n.text("update.up_to_date", currentVersion)
        case .available: return L10n.text("update.available", availableVersionText)
        case .incompatible: return L10n.text("update.requires_system", manifest?.version ?? "", manifest?.minimumSystemVersion ?? "")
        case .failed(let key): return L10n.text(key)
        }
    }

    var menuTitle: String {
        if isChecking { return L10n.text("update.checking") }
        if shouldRemind { return L10n.text("update.menu_available", availableVersionText) }
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
        if isChecking { status = automaticInstallation ? statusBeforeCheck : .idle }
    }

    @MainActor func setAutomaticInstallation(_ enabled: Bool) {
        automaticInstallation = enabled
        defaults.set(enabled, forKey: Self.prefix + "automaticUpdates")
        if !enabled { installer.cancelAutomatic() }
        if enabled && started { checkAutomaticallyIfDue() }
    }

    @MainActor func installUpdate() {
        guard canUpgrade, let update = availableUpdate else { return }
        installer.start(update: update)
        if installer.isActive { showsUpdateWindow = false }
    }

    @MainActor func skipVersion() {
        guard let update = availableUpdate else { return }
        defaults.set(update.release.identifier, forKey: Self.prefix + "skipped")
        objectWillChange.send()
        dismissUpdateWindow()
    }

    @MainActor func remindLater() {
        defaults.set(now().addingTimeInterval(86400), forKey: Self.prefix + "remindAfter")
        objectWillChange.send()
        dismissUpdateWindow()
    }

    @MainActor private func installAutomaticallyIfAllowed() {
        guard automaticInstallation, shouldRemind, canUpgrade, let update = availableUpdate, !installer.isActive else { return }
        let key = Self.prefix + "autoAttempt." + update.release.identifier
        if let last = defaults.object(forKey: key) as? Date, now().timeIntervalSince(last) < 86400 { return }
        defaults.set(now(), forKey: key)
        installer.start(update: update, automatic: true)
    }

    @MainActor func checkAutomaticallyIfDue() {
        guard automaticInstallation, !isChecking, !installer.isActive, client.retryAfter == nil else { return }
        let date = now()
        // At most one proactive check per 24 hours, even if the last attempt failed.
        if let lastChecked, date.timeIntervalSince(lastChecked) >= 0,
           date.timeIntervalSince(lastChecked) < 86400 { return }
        if let attempt = defaults.object(forKey: Self.prefix + "caskLastAttempt") as? Date,
           date.timeIntervalSince(attempt) >= 0, date.timeIntervalSince(attempt) < 86400 { return }
        requestCheck(userInitiated: false)
    }

    @MainActor func requestCheck(userInitiated: Bool = true) {
        guard !isChecking, task == nil, !installer.isActive else { return }
        let generation = checkGeneration
        task = Task { [weak self] in
            guard let self else { return }
            await self.check(userInitiated: userInitiated)
            if self.checkGeneration == generation { self.task = nil }
        }
    }

    @MainActor func check(userInitiated: Bool = true) async {
        guard !Task.isCancelled, !isChecking, userInitiated || automaticInstallation else { return }
        let generation = checkGeneration
        let previousStatus = status
        statusBeforeCheck = previousStatus
        status = .checking
        defaults.set(now(), forKey: Self.prefix + "caskLastAttempt")
        do {
            try Task.checkCancellation()
            guard UpdateVersion(currentVersion) != nil else { throw HomebrewUpdateError.invalidCurrentVersion }
            let update = try await client.fetch(current: UpdateRelease(version: currentVersion, build: currentBuild))
            try Task.checkCancellation()
            guard generation == checkGeneration else { return }
            // A background request may finish after the user turns off checks.
            guard userInitiated || automaticInstallation else {
                status = .idle; showsUpdateWindow = false; return
            }
            let newer = try update.isNewer(than: currentVersion, currentBuild: currentBuild)
            manifest = update
            lastChecked = now()
            defaults.set(lastChecked, forKey: Self.prefix + "caskLastSuccess")
            defaults.set(try JSONEncoder().encode(update), forKey: Self.prefix + "caskManifest")
            status = newer ? (canUpgrade ? .available : .incompatible) : .upToDate
            if !userInitiated { installAutomaticallyIfAllowed() }
        } catch is CancellationError {
            guard generation == checkGeneration else { return }
            status = !userInitiated && !automaticInstallation ? .idle : previousStatus
        } catch {
            guard generation == checkGeneration else { return }
            // Background failures never open windows or erase a known update reminder.
            status = userInitiated ? .failed(Self.messageKey(for: error)) : (automaticInstallation ? previousStatus : .idle)
        }
        if !userInitiated && !automaticInstallation { showsUpdateWindow = false }
    }

    private static func messageKey(for error: Error) -> String {
        switch error as? HomebrewUpdateError {
        case .invalidManifest, .unsupportedSchema: return "update.error_manifest"
        case .invalidCurrentVersion: return "update.error_version"
        case .unavailable: return "update.error_unavailable"
        case .rateLimited: return "update.error_rate_limit"
        default: return "update.error_network"
        }
    }
}
