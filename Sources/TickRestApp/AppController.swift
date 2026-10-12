import AppKit
import Combine
import CoreGraphics
import TickRestCore
import ServiceManagement
import UserNotifications

final class AppController: ObservableObject {
    @Published var settings: Settings
    @Published private(set) var interfaceLanguage = "en"
    @Published var revision = 0
    @Published private var errorKey: String?
    private var errorDetail: String?
    var interfaceLocale: Locale { Locale(identifier: interfaceLanguage) }
    var errorMessage: String? {
        guard let errorKey else { return nil }
        if let errorDetail { return L10n.text(errorKey, errorDetail) }
        return L10n.text(errorKey)
    }
    @Published var launchAtLogin = false
    @Published var notificationStatus = "permission.unknown"
    @Published var fullscreenUnavailable = false
    let engine: Engine
    let store: DataStore
    private lazy var stateWriter = DebouncedStateWriter { [store] in try store.save($0) }
    lazy var wallpapers = WallpaperLibrary(directory: store.url.deletingLastPathComponent().appendingPathComponent("Wallpapers", isDirectory: true))
    var saved: SavedData
    var onEffects: (([EngineEffect]) -> Void)?
    private var timer: Timer?
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private var lastSave = ProcessInfo.processInfo.systemUptime
    private var lastProbe = -Double.infinity
    private var systemAway = false
    private var awayReasons: Set<String> = []
    private var idleAway = false
    private var idleAtSystemAway = false
    private let observers = NotificationObservations()
    private var notificationEnabled = false
    private var lastRestTick: Date?

    init(store disk: DataStore = DataStore()) {
        let loaded = disk.load()
        store = disk; saved = loaded; settings = loaded.settings
        L10n.language = loaded.settings.language
        interfaceLanguage = L10n.resolvedLanguage
        engine = Engine(settings: loaded.settings, snapshot: FileManager.default.fileExists(atPath: disk.url.path) ? loaded.snapshot : nil)
        errorKey = disk.loadErrorKey
        refreshLogin(); refreshNotificationStatus()
    }
    deinit { timer?.invalidate() }
    func begin() {
        let center = NSWorkspace.shared.notificationCenter
        for (reason, begin, end) in [("power", NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification), ("session", NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification)] {
            observers.observe(center, name: begin) { [weak self] _ in self?.beginSystemAway(reason: reason) }
            observers.observe(center, name: end) { [weak self] _ in self?.endSystemAway(reason: reason) }
        }
        // Lock/unlock notifications supplement public workspace session/power events.
        // These notification names are best-effort and must be rechecked on supported OS versions.
        let distributed = DistributedNotificationCenter.default()
        observers.observe(distributed, name: NSNotification.Name("com.apple.screenIsLocked")) { [weak self] _ in self?.beginSystemAway(reason: "lock") }
        observers.observe(distributed, name: NSNotification.Name("com.apple.screenIsUnlocked")) { [weak self] _ in self?.endSystemAway(reason: "lock") }
        timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
        RunLoop.main.add(timer!, forMode: .eventTracking)
        consume()
    }
    func tick() {
        let uptime = ProcessInfo.processInfo.systemUptime
        let elapsed = max(0, uptime - lastTick); lastTick = uptime
        // Avoid charging suspended event loops as active screen use.
        let delta = min(elapsed, 5)
        if uptime - lastProbe >= 5 {
            lastProbe = uptime; probeIdle(); probeFullscreen()
        }
        if engine.isResting { lastRestTick = Date() }
        engine.tick(seconds: delta, now: Date())
        consume()
        if uptime - lastSave >= 30 { persist(); lastSave = uptime }
        revision += 1
    }
    private func probeIdle() {
        // Not touching the keyboard is the expected behavior during an explicit rest.
        guard !systemAway, !engine.isResting else { return }
        // kCGAnyInputEventType tracks keyboard, mouse and tablet activity.
        // .null only tracks null events and does not reset on normal input.
        let anyInputEvent = CGEventType(rawValue: UInt32.max)!
        let systemIdle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInputEvent)
        let idle = min(systemIdle, lastRestTick.map { max(0, Date().timeIntervalSince($0)) } ?? systemIdle)
        if settings.detectIdle && idle >= settings.idleTimeout && !idleAway {
            let observedAt = Date()
            idleAway = true; engine.beginAway(at: observedAt.addingTimeInterval(-idle), observedAt: observedAt); consume()
        } else if idleAway && (!settings.detectIdle || idle < settings.idleTimeout) {
            idleAway = false; engine.endAway(now: Date(), minimumShort: settings.timingModel == .dual ? max(60, settings.shortDuration) : settings.shortDuration); consume()
        }
    }
    private func probeFullscreen() {
        guard settings.avoidFullscreen else { engine.setSuppressed(false); fullscreenUnavailable = false; return }
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        // An application window must not classify its own overlay as a full-screen app.
        if front.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            if !engine.isResting { engine.setSuppressed(false) }
            return
        }
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            fullscreenUnavailable = true; engine.setSuppressed(false); return
        }
        fullscreenUnavailable = false
        let matching = windows.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == front.processIdentifier && ($0[kCGWindowLayer as String] as? Int) == 0 }
        let fullscreen = matching.contains { window in
            guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
            return NSScreen.screens.contains { screen in
                let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
                let display = CGDisplayBounds(id)
                return abs(rect.width - display.width) < 5 && abs(rect.height - display.height) < 5
                    && abs(rect.minX - display.minX) < 5 && abs(rect.minY - display.minY) < 5
            }
        }
        engine.setSuppressed(fullscreen)
    }
    private func beginSystemAway(reason: String) {
        awayReasons.insert(reason)
        guard !systemAway else { return }
        systemAway = true; idleAtSystemAway = idleAway
        engine.beginAway(at: Date()); consume(); persist()
    }
    private func endSystemAway(reason: String) {
        awayReasons.remove(reason)
        guard systemAway, awayReasons.isEmpty else { return }
        systemAway = false; idleAway = false
        engine.endAway(now: Date(), minimumShort: idleAtSystemAway ? max(60, settings.shortDuration) : settings.shortDuration)
        idleAtSystemAway = false; lastTick = ProcessInfo.processInfo.systemUptime
        consume(); persist()
    }
    func update(deferPersistence: Bool = false, _ mutate: (inout Settings) -> Void) {
        var candidate = settings; mutate(&candidate)
        guard candidate != settings else { return }
        if let key = candidate.validationErrorKey { showError(key); return }
        if let pending = engine.pendingPlan {
            var future = candidate; future.restPlan = pending
            if let key = future.validationErrorKey { showError(key); return }
        }
        let themeChanged = candidate.theme != settings.theme
        L10n.language = candidate.language; settings = candidate; engine.updateSettings(candidate)
        interfaceLanguage = L10n.resolvedLanguage
        if themeChanged { applyAppearance() }
        consume()
        if deferPersistence {
            captureSavedState()
            stateWriter.schedule(saved) { [weak self] _ in self?.showError("error.save") }
        } else { persist() }
        revision += 1
    }
    func applyPlan(_ plan: RestPlan) {
        var candidate = settings; candidate.restPlan = plan
        if let key = candidate.validationErrorKey { showError(key); return }
        action { $0.applyPlan(plan, now: Date()) }
    }
    func cancelPendingPlan() { action { $0.cancelPendingPlan() } }
    func applyAppearance() {
        switch settings.theme {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
    func action(_ body: (Engine) -> Void) {
        // Explicit interaction is evidence the user returned; do not wait for the next idle probe.
        if idleAway && !systemAway {
            idleAway = false; engine.endAway(now: Date(), minimumShort: settings.timingModel == .dual ? max(60, settings.shortDuration) : settings.shortDuration)
        }
        body(engine); consume(); persist(); revision += 1
    }
    func pauseMinutes(_ value: Int) { action { $0.setPause(.until(Date().addingTimeInterval(Double(value * 60))), now: Date()) } }
    func pauseToday() {
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!
        action { $0.setPause(.until(tomorrow), now: Date()) }
    }
    func resume() { action { $0.setPause(nil, now: Date()) } }
    func summary(in range: StatisticsDateRange) -> StatisticsSummary {
        StatisticsSummary(records: saved.records, range: range)
    }
    var stateText: String { ReminderDisplay(engine: engine).stateText }
    func consume() {
        if settings != engine.settings { settings = engine.settings }
        let (effects, records) = engine.drain()
        DataStore.append(records, to: &saved.records, now: Date())
        onEffects?(effects)
    }
    func persist() {
        captureSavedState()
        do { try stateWriter.flush(saved) } catch { showError("error.save") }
    }
    private func captureSavedState() {
        saved.settings = settings; saved.snapshot = engine.snapshot(now: Date())
    }
    @discardableResult func clearRecords() -> Bool {
        var cleared = saved
        cleared.records = []
        cleared.settings = settings
        cleared.snapshot = engine.snapshot(now: Date())
        do {
            try stateWriter.flush(cleared)
            saved = cleared
            revision += 1
            return true
        } catch {
            showError("error.save")
            return false
        }
    }
    func refreshLogin() { launchAtLogin = SMAppService.mainApp.status == .enabled }
    func setLogin(_ enabled: Bool) {
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { showError("error.login", detail: error.localizedDescription) }
        refreshLogin()
    }
    func refreshNotificationStatus() {
        // UNUserNotificationCenter requires a proper .app bundle.
        guard Bundle.main.bundleURL.pathExtension == "app" else { notificationStatus = "permission.bundle"; return }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] result in
            DispatchQueue.main.async {
                self?.notificationEnabled = result.authorizationStatus == .authorized || result.authorizationStatus == .provisional
                switch result.authorizationStatus {
                case .authorized, .provisional: self?.notificationStatus = "permission.allowed"
                case .denied: self?.notificationStatus = "permission.denied"
                default: self?.notificationStatus = "permission.unknown"
                }
            }
        }
    }
    func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] _, error in
            DispatchQueue.main.async { if error != nil { self?.showError("error.notification") }; self?.refreshNotificationStatus() }
        }
    }
    func notifyWarning(_ kind: BreakKind, fallback: @escaping () -> Void) {
        guard notificationEnabled else { fallback(); return }
        let content = UNMutableNotificationContent()
        content.title = L10n.text("app.name")
        content.body = L10n.text("warning.body", Int(settings.prewarning), settings.breakTitle(kind), L10n.duration(settings.duration(kind)))
        let request = UNNotificationRequest(identifier: AppIdentity.identifier("prewarning"), content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in if error != nil { DispatchQueue.main.async(execute: fallback) } }
    }
    func removeNotifications() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [AppIdentity.identifier("prewarning")])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [AppIdentity.identifier("prewarning")])
    }
    private var playingSound: NSSound?
    func playReminderSound() {
        playingSound?.stop()
        playingSound = NSSound(named: NSSound.Name(settings.reminderSound.rawValue))
        playingSound?.play()
    }
    private func showError(_ key: String, detail: String? = nil) {
        errorDetail = detail
        errorKey = key
    }
    func dismissError() { errorKey = nil; errorDetail = nil }
}
