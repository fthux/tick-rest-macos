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

    private func setManifest(version: String = "1.10.0", minimum: String = "13.0") {
        UpdateURLProtocol.body = Data("""
        {"schemaVersion":1,"version":"\(version)","minimumSystemVersion":"\(minimum)",
         "releaseNotesURL":"https://github.com/fthux/tick-rest-macos/releases/tag/v\(version)","summary":"Changes"}
        """.utf8)
    }

    private func controller(version: String = "1.0.0", system: String = "13.0.0") -> HomebrewUpdateController {
        HomebrewUpdateController(currentVersion: version, systemVersion: system, defaults: defaults,
                                 client: HomebrewUpdateClient(session: session), now: { [unowned self] in self.date })
    }

    @MainActor func testNewVersionAndRelaunchAfterUpgrade() async throws {
        let updates = controller()
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
        XCTAssertTrue(updates.automaticChecks)
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
        for (code, key) in [(404, "update.error_unavailable"), (429, "update.error_unavailable"),
                            (503, "update.error_unavailable"), (0, "update.error_network")] {
            UpdateURLProtocol.status = code
            let updates = controller()
            await updates.check()
            XCTAssertEqual(updates.status, .failed(key))
            XCTAssertNil(updates.lastChecked)
        }
    }

    @MainActor func testInvalidJSONAndOversizedResponsesAreRejected() async {
        for data in [Data("<html>Not JSON</html>".utf8), Data("{}".utf8), Data(repeating: 32, count: 65537)] {
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
            .replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2").utf8)
        await updates.check()
        XCTAssertEqual(updates.status, .failed("update.error_manifest"), "Unknown format versions are rejected")
    }

    @MainActor func testMissingInstalledVersionDoesNotMakeNetworkRequest() async {
        let updates = controller(version: "—")
        await updates.check()
        XCTAssertEqual(updates.status, .failed("update.error_version"))
        XCTAssertEqual(UpdateURLProtocol.count, 0)
    }

    @MainActor func testDailyCheckGateManualOverrideAndOptOutPersist() async {
        let updates = controller()
        await updates.check()
        updates.checkAutomaticallyIfDue()
        XCTAssertEqual(UpdateURLProtocol.count, 1)
        await updates.check() // A manual check ignores the daily throttle.
        XCTAssertEqual(UpdateURLProtocol.count, 2)
        date = date.addingTimeInterval(86401)
        updates.setAutomaticChecks(false)
        updates.checkAutomaticallyIfDue()
        XCTAssertEqual(UpdateURLProtocol.count, 2)
        XCTAssertFalse(controller().automaticChecks)
        updates.setAutomaticChecks(true)
        updates.checkAutomaticallyIfDue()
        await waitForCheck(updates)
        XCTAssertEqual(UpdateURLProtocol.count, 3)
    }

    @MainActor func testBackgroundFailurePreservesReminderAndRetriesHourly() async {
        let updates = controller()
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
        await waitForCheck(updates)
        XCTAssertEqual(UpdateURLProtocol.count, 3)
    }

    @MainActor func testOptOutHidesCachedReminderAcrossLaunchesButAllowsManualChecks() async {
        let updates = controller()
        await updates.check()
        updates.setAutomaticChecks(false)
        XCTAssertNil(updates.availableUpdate)
        XCTAssertEqual(updates.status, .idle)
        let relaunched = controller()
        XCTAssertFalse(relaunched.automaticChecks)
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
        let pending = Task { await updates.check(userInitiated: false) }
        while !updates.isChecking { await Task.yield() }
        updates.setAutomaticChecks(false)
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
                    var body = try XCTUnwrap(JSONSerialization.jsonObject(with: UpdateURLProtocol.body) as? [String: Any])
                    body["summary"] = String(repeating: "Release notes with improvements and bug fixes.\n", count: 70)
                    UpdateURLProtocol.body = try JSONSerialization.data(withJSONObject: body)
                }
                let updates = controller()
                await updates.check()
                let view = NSHostingView(rootView: HomebrewUpdatePrompt(updates: updates, openHistory: {})
                    .environment(\.locale, L10n.locale)
                    .background(Color(nsColor: .windowBackgroundColor)))
                let size = view.fittingSize
                XCTAssertEqual(size.width, HomebrewUpdatePrompt.contentSize.width, accuracy: 1)
                XCTAssertEqual(size.height, HomebrewUpdatePrompt.contentSize.height, accuracy: 1,
                               "Long notes must scroll without pushing Homebrew steps and actions out of the window")
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

    @MainActor func testCopyCommandStaysOpenAndQuitRequiresSuccessfulCopy() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var quitCount = 0
        let actions = HomebrewUpdateActions(writeText: { text in
            pasteboard.clearContents()
            return pasteboard.setString(text, forType: .string)
        }, quit: {
            XCTAssertEqual(pasteboard.string(forType: .string), HomebrewUpdateConfiguration.upgradeCommand)
            quitCount += 1
        })
        XCTAssertTrue(actions.copyCommand(canUpgrade: true))
        XCTAssertEqual(pasteboard.string(forType: .string), HomebrewUpdateConfiguration.upgradeCommand)
        XCTAssertEqual(quitCount, 0)
        XCTAssertTrue(actions.copyCommandAndQuit(canUpgrade: true))
        XCTAssertEqual(quitCount, 1)

        var attemptedWrite = false
        let failing = HomebrewUpdateActions(writeText: { _ in
            attemptedWrite = true
            return false
        }, quit: { XCTFail("A failed copy must never quit the application") })
        XCTAssertFalse(failing.copyCommand(canUpgrade: false))
        XCTAssertFalse(attemptedWrite, "Incompatible updates must block copying before accessing the clipboard")
        XCTAssertFalse(failing.copyCommandAndQuit(canUpgrade: false))
        XCTAssertFalse(attemptedWrite, "Incompatible updates must not write a command")
        XCTAssertFalse(failing.copyCommandAndQuit(canUpgrade: true))
        XCTAssertTrue(attemptedWrite)
        XCTAssertFalse(failing.copyCommand(canUpgrade: true))
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

    func testCommandUsesActualInstalledPackageAndConfiguredPublicFeed() {
        XCTAssertEqual(HomebrewUpdateConfiguration.upgradeCommand, "brew update && brew upgrade fthux/tap/tickrest")
#if DEBUG
        XCTAssertEqual(HomebrewUpdateConfiguration.feedURL.absoluteString,
                       "https://raw.githubusercontent.com/fthux/test-repo/refs/heads/master/updates/homebrew-update.json")
#else
        XCTAssertEqual(HomebrewUpdateConfiguration.feedURL.absoluteString,
                       "https://raw.githubusercontent.com/fthux/tick-rest-macos/master/updates/homebrew-update.json")
#endif
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
    static var status = 200
    static var count = 0
    static var delay: TimeInterval = 0
    private var pending: DispatchWorkItem?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.count += 1
        XCTAssertEqual(request.url, HomebrewUpdateConfiguration.feedURL)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        if Self.status == 0 {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        let body = Self.body
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
