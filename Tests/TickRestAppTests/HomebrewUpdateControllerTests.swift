import AppKit
import SwiftUI
import XCTest
import TickRestCore
@testable import TickRestApp

final class HomebrewUpdateControllerTests: XCTestCase {
    private var session: URLSession!
    private var defaults: UserDefaults!
    private var suite: String!
    private var date = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUp() {
        super.setUp()
        suite = "HomebrewUpdateTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateURLProtocol.self]
        session = URLSession(configuration: configuration)
        UpdateURLProtocol.status = 200
        UpdateURLProtocol.count = 0
        UpdateURLProtocol.delay = 0
        setManifest()
    }

    override func tearDown() {
        session.invalidateAndCancel()
        defaults.removePersistentDomain(forName: suite)
        session = nil; defaults = nil
        super.tearDown()
    }

    private func setManifest(version: String = "1.10.0", minimum: String = "13.0", build: String? = nil) {
        let system = ["13.0": "ventura", "15.0": "sequoia"][minimum] ?? "ventura"
        let caskVersion = version + (build.map { "," + $0 } ?? "")
        UpdateURLProtocol.body = Data("""
        cask "tickrest" do
          version "\(caskVersion)"
          depends_on macos: :\(system)
          url "https://github.com/fthux/tick-rest-macos/releases/download/v\(version)/TickRest.zip"
        end
        """.utf8)
        UpdateURLProtocol.notes = "Changes"
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("homebrewUpdate.caskHTTP.") && key.contains(".notes.") {
            defaults.removeObject(forKey: key)
        }
    }

    private func controller(version: String = "1.0.0", system: String = "13.0.0") -> HomebrewUpdateController {
        HomebrewUpdateController(currentVersion: version, systemVersion: system, defaults: defaults,
                                 client: HomebrewUpdateClient(session: session, defaults: defaults, now: { [unowned self] in self.date }), now: { [unowned self] in self.date })
    }

    @MainActor func testNewVersionAndRelaunchAfterUpgrade() async throws {
        let updates = controller()
        updates.setAutomaticInstallation(true)
        await updates.check()
        XCTAssertEqual(updates.status, .available)
        XCTAssertEqual(updates.availableUpdate?.version, "1.10.0")
        XCTAssertTrue(updates.canUpgrade)
        XCTAssertFalse(updates.showsUpdateWindow, "Checks must never open an update window automatically")
        XCTAssertEqual(updates.lastChecked, date)
        XCTAssertEqual(controller().availableUpdate?.version, "1.10.0", "Keep reminders across launches")
        XCTAssertNil(controller(version: "1.10.0").availableUpdate, "Use the actual running version after an upgrade")
    }

    @MainActor func testEqualAndOlderFeedNeverOfferDowngrade() async {
        for version in ["1.10.0", "2.0.0"] {
            let updates = controller(version: version)
            await updates.check()
            XCTAssertEqual(updates.status, .upToDate)
            XCTAssertNil(updates.availableUpdate)
        }
    }

    func testDebugAndReleaseDoNotShareCachedVersionsOrCheckPreferences() {
#if DEBUG
        let otherPrefix = "homebrewUpdate.release."
#else
        let otherPrefix = "homebrewUpdate.debug."
#endif
        defaults.set(UpdateURLProtocol.body, forKey: otherPrefix + "manifest")
        defaults.set(date, forKey: otherPrefix + "lastSuccess")
        defaults.set(false, forKey: otherPrefix + "automatic")
        let updates = controller()
        XCTAssertNil(updates.availableUpdate)
        XCTAssertNil(updates.lastChecked)
        XCTAssertFalse(updates.automaticInstallation)
    }

    @MainActor func testSystemRequirementBlocksUpgradeCommand() async {
        setManifest(minimum: "15.0")
        let updates = controller()
        await updates.check()
        XCTAssertEqual(updates.status, .incompatible)
        XCTAssertNotNil(updates.availableUpdate)
        XCTAssertFalse(updates.canUpgrade)
    }

    @MainActor func testUnavailableFeedAndOfflineAreErrorsNotUpToDate() async {
        for (code, key) in [(404, "update.error_unavailable"), (503, "update.error_unavailable"), (0, "update.error_network")] {
            UpdateURLProtocol.status = code
            let updates = controller()
            await updates.check()
            XCTAssertEqual(updates.status, .failed(key))
            XCTAssertNil(updates.lastChecked)
        }
    }

    @MainActor func testInvalidCaskAndOversizedResponsesAreRejected() async {
        for data in [Data("<html>Not a cask</html>".utf8), Data("{}".utf8), Data(repeating: 32, count: 65537)] {
            UpdateURLProtocol.body = data
            let updates = controller()
            await updates.check()
            XCTAssertEqual(updates.status, .failed("update.error_manifest"))
            XCTAssertNil(updates.manifest)
        }
        setManifest(version: "2.0.0-beta")
        let updates = controller()
        await updates.check()
        XCTAssertEqual(updates.status, .failed("update.error_manifest"))
        setManifest()
        UpdateURLProtocol.body = Data(String(decoding: UpdateURLProtocol.body, as: UTF8.self)
            .replacingOccurrences(of: "cask \"tickrest\"", with: "cask \"other\"").utf8)
        await updates.check()
        XCTAssertEqual(updates.status, .failed("update.error_manifest"), "A different Cask token must be rejected")
    }

    @MainActor func testMissingInstalledVersionDoesNotMakeNetworkRequest() async {
        let updates = controller(version: "—")
        await updates.check()
        XCTAssertEqual(updates.status, .failed("update.error_version"))
        XCTAssertEqual(UpdateURLProtocol.count, 0)
    }

    @MainActor func testDailyCheckGateManualOverrideAndOptOutPersist() async {
        let updates = controller()
        updates.setAutomaticInstallation(true)
        await updates.check()
        updates.checkAutomaticallyIfDue()
        XCTAssertEqual(UpdateURLProtocol.count, 1)
        await updates.check() // A manual check ignores the daily throttle.
        XCTAssertEqual(UpdateURLProtocol.count, 2)
        date = date.addingTimeInterval(86401)
        updates.setAutomaticInstallation(false)
        updates.checkAutomaticallyIfDue()
        XCTAssertEqual(UpdateURLProtocol.count, 2)
        XCTAssertFalse(controller().automaticInstallation)
        updates.setAutomaticInstallation(true)
        updates.checkAutomaticallyIfDue()
        await waitForCheck(updates)
        XCTAssertEqual(UpdateURLProtocol.count, 3)
    }

    @MainActor func testBackgroundFailurePreservesReminderAndRetriesOnlyNextDay() async {
        let updates = controller()
        updates.setAutomaticInstallation(true)
        await updates.check()
        let success = updates.lastChecked
        date = date.addingTimeInterval(86401)
        UpdateURLProtocol.status = 0
        await updates.check(userInitiated: false)
        XCTAssertEqual(updates.status, .available)
        XCTAssertNotNil(updates.availableUpdate)
        XCTAssertEqual(updates.lastChecked, success)
        updates.checkAutomaticallyIfDue()
        XCTAssertEqual(UpdateURLProtocol.count, 2)
        date = date.addingTimeInterval(3601)
        updates.checkAutomaticallyIfDue()
        XCTAssertEqual(UpdateURLProtocol.count, 2, "Failed automatic checks must not retry hourly")
        date = date.addingTimeInterval(86401)
        updates.checkAutomaticallyIfDue()
        await waitForCheck(updates)
        XCTAssertEqual(UpdateURLProtocol.count, 3)
    }

    @MainActor func testOptOutHidesCachedReminderAcrossLaunchesButAllowsManualChecks() async {
        let updates = controller()
        await updates.check()
        updates.setAutomaticInstallation(false)
        XCTAssertNotNil(updates.availableUpdate, "Turning off automation keeps the current manual result")
        let relaunched = controller()
        XCTAssertFalse(relaunched.automaticInstallation)
        XCTAssertNil(relaunched.availableUpdate)
        XCTAssertEqual(relaunched.menuTitle, L10n.text("update.check"))
        relaunched.start()
        await Task.yield()
        XCTAssertEqual(UpdateURLProtocol.count, 1, "Opting out must prevent startup requests")
        await relaunched.check()
        XCTAssertEqual(UpdateURLProtocol.count, 2)
        XCTAssertEqual(relaunched.status, .available, "Manual checks remain available while opted out")
        XCTAssertNil(controller().availableUpdate, "Manual results must not restore automatic reminders next launch")
        relaunched.stop()
    }

    @MainActor func testOptOutDuringBackgroundRequestDoesNotRestoreReminder() async {
        UpdateURLProtocol.delay = 0.05
        let updates = controller()
        updates.setAutomaticInstallation(true)
        let pending = Task { await updates.check(userInitiated: false) }
        while !updates.isChecking { await Task.yield() }
        updates.setAutomaticInstallation(false)
        await pending.value
        XCTAssertEqual(updates.status, .idle)
        XCTAssertNil(updates.availableUpdate)
        XCTAssertNil(controller().availableUpdate)
    }

    @MainActor func testUnifiedPromptFitsAllLanguagesAndCapsLongSummaries() async throws {
        _ = NSApplication.shared
        let previousLanguage = L10n.language
        defer { L10n.language = previousLanguage }
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/homebrew-update-layout")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for language in ["en", "zh-Hans", "zh-Hant", "ja", "ko"] {
            L10n.language = language
            for longSummary in [false, true] {
                setManifest()
                if longSummary {
                    UpdateURLProtocol.notes = String(repeating: "Release notes with improvements and bug fixes.\n", count: 70)
                }
                let updates = controller()
                await updates.check()
                let view = NSHostingView(rootView: HomebrewUpdatePrompt(updates: updates)
                    .environment(\.locale, L10n.locale)
                    .background(Color(nsColor: .windowBackgroundColor)))
                let size = view.fittingSize
                XCTAssertEqual(size.width, HomebrewUpdatePrompt.contentSize.width, accuracy: 1)
                XCTAssertEqual(size.height, HomebrewUpdatePrompt.contentSize.height, accuracy: 1,
                               "Long notes must scroll without pushing actions out of the window")
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = view
                view.frame.size = size
                window.orderBack(nil)
                try await Task.sleep(nanoseconds: 150_000_000)
                view.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: output.appendingPathComponent("\(language)-\(longSummary ? "long" : "short").png"))
                window.close()
            }
        }
    }

    @MainActor func testAboutUpdateSectionFitsAllLanguagesWithOneAutomaticOption() async throws {
        _ = NSApplication.shared
        let previousLanguage = L10n.language
        defer { L10n.language = previousLanguage }
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/homebrew-update-layout")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for language in ["en", "zh-Hans", "zh-Hant", "ja", "ko"] {
            L10n.language = language
            let updates = controller()
            let view = NSHostingView(rootView: HomebrewUpdateSection(updates: updates)
                .environment(\.locale, L10n.locale)
                .padding(20).frame(width: 620)
                .background(Color(nsColor: .windowBackgroundColor)))
            let size = view.fittingSize
            XCTAssertEqual(size.width, 620, accuracy: 1)
            XCTAssertLessThan(size.height, 340, "The single option and explanation must fit the About page")
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            view.frame.size = size
            window.orderBack(nil)
            try await Task.sleep(nanoseconds: 150_000_000)
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent("about-\(language).png"))
            window.close()
        }
    }

    @MainActor func testConcurrentChecksShareSingleRequest() async {
        UpdateURLProtocol.delay = 0.05
        let updates = controller()
        async let first: Void = updates.check()
        async let second: Void = updates.check()
        _ = await (first, second)
        XCTAssertEqual(UpdateURLProtocol.count, 1)
        XCTAssertEqual(updates.status, .available)
    }

    @MainActor func testAutomaticInstallDefaultsOffAndPreferencesStayConsistent() {
        let updates = controller()
        XCTAssertFalse(updates.automaticInstallation)
        updates.setAutomaticInstallation(true)
        XCTAssertTrue(controller().automaticInstallation)
        updates.setAutomaticInstallation(false)
        XCTAssertFalse(updates.automaticInstallation)
        XCTAssertFalse(controller().automaticInstallation)
        updates.setAutomaticInstallation(true)
        XCTAssertTrue(updates.automaticInstallation)
        XCTAssertTrue(controller().automaticInstallation)
    }

    @MainActor func testLegacyPreferencesOnlyMigrateExplicitInstallationConsent() {
        let prefix = HomebrewUpdateConfiguration.preferencesPrefix
        defaults.set(true, forKey: prefix + "automatic")
        XCTAssertFalse(controller().automaticInstallation, "Old check-only consent must never authorize installation")
        defaults.set(true, forKey: prefix + "automaticInstall")
        XCTAssertTrue(controller().automaticInstallation)
        defaults.set(false, forKey: prefix + "automatic")
        XCTAssertFalse(controller().automaticInstallation)
        defaults.set(true, forKey: prefix + "automaticUpdates")
        XCTAssertTrue(controller().automaticInstallation, "The new unified preference takes precedence")
        defaults.set(false, forKey: prefix + "automaticUpdates")
        defaults.set(true, forKey: prefix + "automatic")
        XCTAssertFalse(controller().automaticInstallation)
    }

    @MainActor func testFailedDailyAttemptPersistsAcrossRelaunchAndManualRetryStillWorks() async {
        UpdateURLProtocol.status = 0
        let updates = controller()
        updates.setAutomaticInstallation(true)
        await updates.check(userInitiated: false)
        XCTAssertNil(updates.lastChecked)
        let relaunched = controller()
        relaunched.start()
        await Task.yield()
        XCTAssertEqual(UpdateURLProtocol.count, 1)
        UpdateURLProtocol.status = 200
        await relaunched.check()
        XCTAssertEqual(UpdateURLProtocol.count, 2)
        XCTAssertEqual(relaunched.status, .available)
        relaunched.stop()
    }

    @MainActor func testEnablingUnifiedOptionStartsDueCheckAndDisabledStartupDoesNot() async {
        setManifest(version: "1.0.0")
        let updates = controller()
        updates.start()
        await Task.yield()
        XCTAssertEqual(UpdateURLProtocol.count, 0)
        updates.setAutomaticInstallation(true)
        await waitForCheck(updates)
        XCTAssertEqual(UpdateURLProtocol.count, 1)
        XCTAssertEqual(updates.status, .upToDate)
        updates.stop()
    }

    @MainActor func testRateLimitHasSpecificUserMessageAndNoImmediateRetry() async {
        UpdateURLProtocol.status = 429
        let updates = controller()
        await updates.check()
        XCTAssertEqual(updates.status, .failed("update.error_rate_limit"))
        XCTAssertEqual(UpdateURLProtocol.count, 1)
        await updates.check()
        XCTAssertEqual(updates.status, .failed("update.error_rate_limit"))
        XCTAssertEqual(UpdateURLProtocol.count, 1)
    }

    @MainActor func testSkipAndSnoozePersistButManualChecksStillShowUpdates() async {
        let updates = controller()
        await updates.check()
        updates.skipVersion()
        XCTAssertFalse(updates.shouldRemind)
        XCTAssertFalse(controller().shouldRemind)
        updates.showAvailableUpdate()
        XCTAssertTrue(updates.showsUpdateWindow)
        setManifest(version: "1.11.0")
        await updates.check()
        XCTAssertTrue(updates.shouldRemind, "Skipping one release must not hide a later release")
        updates.remindLater()
        XCTAssertFalse(controller().shouldRemind)
        date.addTimeInterval(86401)
        XCTAssertTrue(updates.shouldRemind)
    }

    @MainActor func testBuildUpdatesAndChannelValidation() async throws {
        setManifest(version: "1.0.0", build: "2")
        let updates = HomebrewUpdateController(currentVersion: "1.0.0", currentBuild: "1", defaults: defaults,
            client: HomebrewUpdateClient(session: session, defaults: defaults, now: { [unowned self] in self.date }),
            now: { [unowned self] in self.date })
        await updates.check()
        XCTAssertEqual(updates.status, .available)
        XCTAssertEqual(updates.availableVersionText, "1.0.0 (2)")
        XCTAssertEqual(updates.currentVersionText, "1.0.0 (1)")
        UpdateURLProtocol.body = Data(String(decoding: UpdateURLProtocol.body, as: UTF8.self)
            .replacingOccurrences(of: "cask \"tickrest\"", with: "cask \"tickrest-dev\"").utf8)
        await updates.check()
        XCTAssertEqual(updates.status, .failed("update.error_manifest"), "Stable clients must reject a development Cask")
    }

    @MainActor func testHandoffRequiresSavedStateAndApprovalBeforeQuit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let job = UpdateJob(installation: HomebrewInstallation(brew: URL(fileURLWithPath: "/usr/local/bin/brew"),
            channel: .dev, app: root.appendingPathComponent("Tick Rest.app"), architecture: "universal",
            current: UpdateRelease(version: "1.0.0", build: "1")), required: UpdateRelease(version: "1.1.0"),
            parentPID: 1234, language: "en", automatic: false)
        let failedStore = try UpdateJobStore.create(job, root: root.appendingPathComponent("failed"))
        try failedStore.write(UpdateJobState(.waiting), named: "state.json")
        let failed = HomebrewUpgradeCoordinator()
        failed.prepareForInstallation = { throw CocoaError(.fileWriteNoPermission) }
        failed.quitForInstallation = { XCTFail("Must not quit when state cannot be saved") }
        failed.handoff(failedStore)
        XCTAssertFalse(failedStore.hasSignal("approved.json"))
        XCTAssertTrue(failedStore.hasSignal("cancel.json"))
        XCTAssertEqual(failed.state?.failure, .save)
        let store = try UpdateJobStore.create(job, root: root.appendingPathComponent("success"))
        try store.write(UpdateJobState(.waiting), named: "state.json")
        let coordinator = HomebrewUpgradeCoordinator()
        var saved = false, quitCount = 0
        coordinator.prepareForInstallation = { saved = true }
        coordinator.quitForInstallation = {
            XCTAssertTrue(saved)
            XCTAssertTrue(store.hasSignal("approved.json"))
            quitCount += 1
        }
        coordinator.handoff(store)
        coordinator.handoff(store)
        XCTAssertEqual(quitCount, 1)
    }

    @MainActor func testUpdatePreparationFlushesPendingSettingsAndRestOutcome() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let previousLanguage = L10n.language
        defer { L10n.language = previousLanguage }
        let disk = DataStore(url: root.appendingPathComponent("state.json"))
        let model = AppController(store: disk)
        model.update(deferPersistence: true) { $0.language = "zh-Hans" }
        model.engine.startNow(.short, now: Date())
        XCTAssertTrue(model.engine.isResting)
        try model.prepareForUpdate()
        XCTAssertFalse(model.engine.isResting)
        let saved = disk.load()
        XCTAssertEqual(saved.settings.language, "zh-Hans")
        XCTAssertTrue(saved.records.contains { $0.outcome == .ended })
        try FileManager.default.removeItem(at: disk.url)
        try FileManager.default.createDirectory(at: disk.url, withIntermediateDirectories: true)
        XCTAssertThrowsError(try model.prepareForUpdate(), "Disk errors must propagate to prevent handoff")
    }

    @MainActor func testInteractiveCheckUsesNativeProgressAndCanBeCancelled() async throws {
        _ = NSApplication.shared
        UpdateURLProtocol.delay = 0.2
        let updates = controller()
        let presenter = HomebrewUpdateWindowController(updates: updates)
        defer { presenter.close(); updates.stop() }
        updates.checkInteractively()
        for _ in 0..<100 {
            if presenter.window != nil && updates.isChecking { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let progressWindow = try XCTUnwrap(presenter.window)
        XCTAssertNil(presenter.alert)
        XCTAssertTrue(progressWindow is NSPanel)
        updates.checkInteractively()
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertTrue(presenter.window === progressWindow, "Repeated clicks must reuse the check window")
        progressWindow.performClose(nil)
        await waitForCheck(updates)
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertFalse(updates.showsUpdateWindow)
        XCTAssertNil(updates.availableUpdate)
        XCTAssertNil(presenter.window, "Cancelled checks must not show a late result")
        XCTAssertEqual(UpdateURLProtocol.count, 1)
    }

    @MainActor func testInteractiveResultsAndRetryUseNativeAlerts() async throws {
        _ = NSApplication.shared
        let updates = controller(version: "1.10.0")
        var opened: URL?
        let presenter = HomebrewUpdateWindowController(updates: updates, openURL: { opened = $0 })
        defer { presenter.close(); updates.stop() }
        UpdateURLProtocol.status = 503
        updates.checkInteractively()
        await waitForCheck(updates)
        try await Task.sleep(nanoseconds: 100_000_000)
        let failed = try XCTUnwrap(presenter.alert)
        XCTAssertEqual(failed.messageText, L10n.text("update.failed_title"))
        UpdateURLProtocol.status = 200
        failed.buttons[0].performClick(nil)
        await waitForCheck(updates)
        try await Task.sleep(nanoseconds: 100_000_000)
        let latest = try XCTUnwrap(presenter.alert)
        XCTAssertEqual(latest.messageText, L10n.text("update.latest_title"))
        XCTAssertEqual(latest.informativeText, L10n.text("update.latest_body", "1.10.0"))
        latest.buttons.last?.performClick(nil)
        XCTAssertEqual(opened, HomebrewUpdateManifest.defaultReleaseHistoryURL)
        latest.buttons[0].performClick(nil)
        XCTAssertFalse(updates.showsUpdateWindow)
        XCTAssertNil(presenter.window)
    }

    @MainActor func testCancelledRequestCannotOverwriteImmediateNewCheck() async throws {
        UpdateURLProtocol.delay = 0.1
        let updates = controller()
        updates.checkInteractively()
        while UpdateURLProtocol.count == 0 { await Task.yield() }
        updates.dismissUpdateWindow()
        XCTAssertFalse(updates.isChecking)
        setManifest(version: "1.0.0")
        updates.checkInteractively()
        await waitForCheck(updates)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(UpdateURLProtocol.count, 2)
        XCTAssertEqual(updates.status, .upToDate)
        XCTAssertEqual(updates.manifest?.version, "1.0.0")
        XCTAssertTrue(updates.showsUpdateWindow)
        updates.dismissUpdateWindow()
        updates.stop()
        XCTAssertFalse(updates.showsUpdateWindow, "Stopping the service must not reopen a result window")
    }

    @MainActor func testNativeUpdateWindowsRenderInFiveLanguages() async throws {
        _ = NSApplication.shared
        let previousLanguage = L10n.language
        defer { L10n.language = previousLanguage }
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/homebrew-update-native")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for language in ["en", "zh-Hans", "zh-Hant", "ja", "ko"] {
            L10n.language = language
            for state in ["checking", "latest", "available", "failed", "incompatible"] {
                setManifest(minimum: state == "incompatible" ? "15.0" : "13.0")
                UpdateURLProtocol.status = state == "failed" ? 503 : 200
                UpdateURLProtocol.delay = state == "checking" ? 0.3 : 0
                let updates = controller(version: state == "latest" ? "1.10.0" : "1.0.0")
                let presenter = HomebrewUpdateWindowController(updates: updates)
                updates.checkInteractively()
                if state != "checking" { await waitForCheck(updates) }
                try await Task.sleep(nanoseconds: 100_000_000)
                let window = try XCTUnwrap(presenter.window)
                if state == "available" || state == "incompatible" {
                    XCTAssertNil(presenter.alert)
                    XCTAssertEqual(window.title, L10n.text("update.prompt_window_title"))
                    XCTAssertEqual(window.contentView?.frame.size, HomebrewUpdatePrompt.contentSize)
                }
                if state == "latest" {
                    XCTAssertEqual(presenter.alert?.messageText, L10n.text("update.latest_title"))
                    XCTAssertEqual(presenter.alert?.informativeText, L10n.text("update.latest_body", "1.10.0"))
                    XCTAssertFalse(presenter.alert?.informativeText.contains("{appName}") ?? true)
                    if language == "en" {
                        XCTAssertEqual(presenter.alert?.informativeText,
                                       "Tick Rest 1.10.0 is currently the newest version available.")
                    }
                }
                let frame = try XCTUnwrap(window.contentView?.superview)
                frame.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
                frame.cacheDisplay(in: frame.bounds, to: bitmap)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: output.appendingPathComponent("\(language)-\(state).png"))
                updates.dismissUpdateWindow()
                presenter.close()
                if state == "checking" {
                    await waitForCheck(updates)
                    try await Task.sleep(nanoseconds: 250_000_000)
                }
                updates.stop()
            }
        }
    }

    @MainActor func testRapidRepeatedClicksStartOnlyOneCheck() async {
        let updates = controller()
        updates.requestCheck()
        updates.requestCheck()
        await waitForCheck(updates)
        XCTAssertEqual(UpdateURLProtocol.count, 1)
        XCTAssertEqual(updates.status, .available)
    }

    @MainActor func testStatusTextRefreshesWhenLanguageChanges() async {
        let oldLanguage = L10n.language
        defer { L10n.language = oldLanguage }
        let updates = controller()
        await updates.check()
        for language in ["en", "zh-Hans", "zh-Hant", "ja", "ko"] {
            L10n.language = language
            XCTAssertEqual(updates.statusText, L10n.text("update.available", "1.10.0"))
            XCTAssertEqual(updates.menuTitle, L10n.text("update.menu_available", "1.10.0"))
        }
    }

    func testConfiguredPublicCask() {
        XCTAssertEqual(HomebrewUpdateConfiguration.caskURL, HomebrewUpdateConfiguration.channel.caskURL)
        XCTAssertEqual(HomebrewUpdateConfiguration.caskURL.host, "raw.githubusercontent.com")
        XCTAssertTrue(HomebrewUpdateConfiguration.caskURL.path.contains("/homebrew-tap/HEAD/Casks/"))
    }

    @MainActor private func waitForCheck(_ updates: HomebrewUpdateController) async {
        // Let requestCheck's task start, then wait for the local URLProtocol response.
        await Task.yield()
        for _ in 0..<100 {
            if !updates.isChecking { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Update check did not finish")
    }
}

private final class UpdateURLProtocol: URLProtocol {
    static var body = Data()
    static var notes = "Changes"
    static var status = 200
    static var count = 0
    static var delay: TimeInterval = 0
    private var pending: DispatchWorkItem?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        let isNotes = request.url!.path.contains("/releases/tags/")
        let isAPI = request.url == HomebrewUpdateConfiguration.channel.caskAPIURL
        if !isNotes && !isAPI {
            Self.count += 1
            XCTAssertEqual(request.url, HomebrewUpdateConfiguration.caskURL)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/plain")
        }
        if !isNotes && Self.status == 0 {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let status = isNotes ? 200 : Self.status
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        let body: Data
        if isNotes {
            body = try! JSONSerialization.data(withJSONObject: ["body": Self.notes, "draft": false, "prerelease": false])
        } else if isAPI && status == 200 {
            body = try! JSONSerialization.data(withJSONObject: ["type": "file", "encoding": "base64", "content": Self.body.base64EncodedString()])
        } else { body = Self.body }
        let send = { [self] in
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        if Self.delay > 0 {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.pending?.isCancelled == false else { return }
                defer { self.pending = nil }
                send()
            }
            pending = work
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.delay, execute: work)
        }
        else { send() }
    }
    override func stopLoading() { pending?.cancel(); pending = nil }
}
