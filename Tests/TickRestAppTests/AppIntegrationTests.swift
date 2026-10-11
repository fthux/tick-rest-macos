import AppKit
import SwiftUI
import XCTest
import TickRestCore
@testable import TickRestApp

/// These tests instantiate the actual SwiftUI views and AppKit panels. They do
/// not require Accessibility automation and never use the user's actual store.
final class AppIntegrationTests: XCTestCase {
    @MainActor private static var applicationInitialized = false
    @MainActor
    private func withFixture(_ body: @MainActor (AppController, WindowCoordinator, URL) async throws -> Void) async throws {
        _ = NSApplication.shared
        if !Self.applicationInitialized {
            NSApp.setActivationPolicy(.accessory)
            NSApp.finishLaunching()
            // SwiftUI creates its accessibility subtree lazily. Enable enhanced
            // accessibility only in this isolated test process, not in the user's app.
            NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
            Self.applicationInitialized = true
        }
        let previousLanguage = L10n.language
        let previousAppearance = NSApp.appearance
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tickrest-native-test-\(UUID())")
        let disk = DataStore(url: directory.appendingPathComponent("state.json"))
        var data = SavedData(); data.settings.detectIdle = false
        data.settings.avoidFullscreen = false; data.settings.prewarning = 0
        data.settings.language = "en"; data.settings.onboardingComplete = true
        try disk.save(data)
        let model = AppController(store: disk)
        let coordinator = WindowCoordinator(model: model)
        model.onEffects = { [weak coordinator] effects in coordinator?.apply(effects) }
        defer {
            model.onEffects = nil; coordinator.hide(restoreFocus: false)
            NSApp.appearance = previousAppearance; L10n.language = previousLanguage
            try? FileManager.default.removeItem(at: directory)
        }
        try await body(model, coordinator, directory)
    }

    @MainActor private var panels: [ReminderPanel] {
        NSApp.windows.compactMap { $0 as? ReminderPanel }.filter(\.isVisible)
    }

    @MainActor private func accessibilityValue(_ object: NSObject, _ selectorName: String) -> AnyObject? {
        let selector = NSSelectorFromString(selectorName)
        if object.responds(to: selector), let value = object.perform(selector)?.takeUnretainedValue() { return value }
        // AppKit's outline-row proxies still expose the legacy attribute interface.
        let attribute: NSAccessibility.Attribute
        switch selectorName {
        case "accessibilityRole": attribute = .role
        case "accessibilityLabel": attribute = .description
        case "accessibilityTitle": attribute = .title
        case "accessibilityChildren": attribute = .children
        default: return nil
        }
        return object.accessibilityAttributeValue(attribute) as AnyObject?
    }

    @MainActor private func findButton(named title: String, in root: NSObject) -> NSObject? {
        var pending: [NSObject] = [root]
        var visited: Set<ObjectIdentifier> = []
        while !pending.isEmpty {
            let element = pending.removeLast()
            guard visited.insert(ObjectIdentifier(element as AnyObject)).inserted else { continue }
            let role = accessibilityValue(element, "accessibilityRole") as? String
            let label = accessibilityValue(element, "accessibilityLabel") as? String
            let controlTitle = accessibilityValue(element, "accessibilityTitle") as? String
            if role == NSAccessibility.Role.button.rawValue, label == title || controlTitle == title { return element }
            pending += (accessibilityValue(element, "accessibilityChildren") as? [NSObject]) ?? []
        }
        return nil
    }

    @MainActor private func button(named title: String, in root: NSObject) throws -> NSObject {
        if let found = findButton(named: title, in: root) { return found }
        XCTFail("Native accessibility tree has no button named \(title)")
        throw NSError(domain: "TickRestNativeTest", code: 1)
    }

    @MainActor private func press(_ object: NSObject) -> Bool {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard object.responds(to: selector) else { return false }
        // SwiftUI accessibility nodes implement the public Objective-C action,
        // but do not declare conformance to the full NSAccessibility protocol.
        typealias PressAction = @convention(c) (AnyObject, Selector) -> Bool
        let action = unsafeBitCast(object.method(for: selector), to: PressAction.self)
        return action(object, selector)
    }

    @MainActor private func writeSnapshot<V: View>(_ root: V, name: String, size: NSSize) throws {
        let view = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { window.close() }
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let bytes = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(bytes.count, 5000, "A native view should render actual content")
        XCTAssertEqual(bitmap.pixelsWide, Int(size.width * view.window!.backingScaleFactor))
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let output = project.appendingPathComponent(".build/native-ui-audit")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try bytes.write(to: output.appendingPathComponent(name + ".png"))
    }

    func testSettingsPagesRenderInAllFiveLanguages() async throws {
        try await withFixture { model, _, _ in
            for language in ["en", "zh-Hans", "zh-Hant", "ja", "ko"] {
                model.update { $0.language = language }
                let navigation = SettingsNavigation()
                for page in SettingsPage.allCases {
                    navigation.page = page
                    try self.writeSnapshot(SettingsView(model: model, navigation: navigation),
                                           name: "settings-\(language)-\(page.rawValue)", size: NSSize(width: 860, height: 640))
                }
            }
        }
    }

    func testCardSizesRenderWaitingAndRunningInEveryLanguage() async throws {
        try await withFixture { model, _, _ in
            model.update { $0.breakStartMode = .manual }
            for language in ["en", "zh-Hans", "zh-Hant", "ja", "ko"] {
                model.update { $0.language = language }
                for size in GentleReminderSize.allCases {
                    model.engine.tick(seconds: 1200, now: Date()); model.consume()
                    // Advance startup/settings grace before capturing the waiting state.
                    if model.engine.reminder == nil {
                        model.engine.tick(seconds: 30, now: Date()); model.engine.tick(seconds: 1, now: Date()); model.consume()
                    }
                    XCTAssertNotNil(model.engine.reminder)
                    for running in [false, true] {
                        if running { model.action { $0.start(now: Date()) } }
                        let width = GentleCardLayout(size: size).width
                        let root = RestCard(model: model, size: size, preview: false, previewEnd: {})
                        let hosting = NSHostingView(rootView: root.frame(width: width))
                        hosting.sizingOptions = [.intrinsicContentSize]
                        let height = ceil(hosting.fittingSize.height)
                        XCTAssertGreaterThan(height, 80)
                        XCTAssertLessThan(height, NSScreen.main!.visibleFrame.height)
                        try self.writeSnapshot(root, name: "card-\(language)-\(size.rawValue)-\(running ? "running" : "waiting")",
                                               size: NSSize(width: width, height: height))
                    }
                    model.action { $0.skip(now: Date()) }
                }
            }
        }
    }

    func testAllSelectedSoundNamesResolveToNativeSystemSounds() async throws {
        try await withFixture { _, _, _ in
            for sound in ReminderSound.allCases {
                XCTAssertNotNil(NSSound(named: NSSound.Name(sound.rawValue)), sound.rawValue)
            }
        }
    }

    func testEscapeEndsARunningCardButSkipsAWaitingCard() async throws {
        try await withFixture { model, windows, _ in
            model.action { $0.startNow(.short, now: Date()) }
            let runningPanel = try XCTUnwrap(self.panels.first)
            XCTAssertEqual(self.panels.count, 1)
            XCTAssertGreaterThan(runningPanel.frame.height, 80)
            model.engine.tick(seconds: 2, now: Date()); model.consume()
            runningPanel.cancelOperation(nil)
            XCTAssertFalse(runningPanel.isVisible)
            XCTAssertFalse(model.engine.isResting)
            XCTAssertEqual(model.saved.records.filter { $0.outcome == .ended }.count, 1)
            model.update { $0.breakStartMode = .manual }
            model.engine.tick(seconds: 1200, now: Date()); model.engine.tick(seconds: 1, now: Date()); model.consume()
            let waitingPanel = try XCTUnwrap(self.panels.first)
            XCTAssertFalse(model.engine.isResting)
            waitingPanel.cancelOperation(nil)
            XCTAssertFalse(waitingPanel.isVisible)
            XCTAssertEqual(model.saved.records.filter { $0.outcome == .skipped }.count, 1)
            windows.hide()
        }
    }

    func testRealCardButtonsStartPostponeSkipAndClose() async throws {
        try await withFixture { model, _, _ in
            model.update { $0.breakStartMode = .manual }
            model.engine.tick(seconds: 1200, now: Date()); model.engine.tick(seconds: 1, now: Date()); model.consume()
            var panel = try XCTUnwrap(self.panels.first)
            try await Task.sleep(nanoseconds: 100_000_000)
            let start = try self.button(named: L10n.text("rest.start"), in: panel)
            XCTAssertTrue(self.press(start))
            XCTAssertTrue(model.engine.isResting)
            try await Task.sleep(nanoseconds: 100_000_000)
            let postpone = try self.button(named: L10n.text("rest.defer", 2), in: panel)
            XCTAssertTrue(self.press(postpone))
            XCTAssertFalse(panel.isVisible)
            XCTAssertEqual(model.engine.reminder?.postponements, 1)
            model.engine.tick(seconds: 120, now: Date()); model.consume()
            panel = try XCTUnwrap(self.panels.first)
            try await Task.sleep(nanoseconds: 100_000_000)
            let skip = try self.button(named: L10n.text("rest.skip"), in: panel)
            XCTAssertTrue(self.press(skip))
            XCTAssertFalse(panel.isVisible)
            XCTAssertEqual(model.saved.records.filter { $0.outcome == .skipped }.count, 1)
            model.action { $0.startNow(.short, now: Date()) }
            panel = try XCTUnwrap(self.panels.first)
            try await Task.sleep(nanoseconds: 100_000_000)
            let close = try self.button(named: L10n.text("common.close"), in: panel)
            XCTAssertTrue(self.press(close))
            XCTAssertFalse(panel.isVisible)
            XCTAssertEqual(model.saved.records.filter { $0.outcome == .ended }.count, 1)
        }
    }

    func testRealSettingsSidebarButtonsNavigateToEveryPage() async throws {
        try await withFixture { model, _, _ in
            let navigation = SettingsNavigation()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 640),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: SettingsView(model: model, navigation: navigation))
            defer { window.close() }
            window.orderFrontRegardless()
            for page in SettingsPage.allCases {
                try await Task.sleep(nanoseconds: 100_000_000)
                let control = try self.button(named: page.title, in: window)
                XCTAssertTrue(self.press(control))
                XCTAssertEqual(navigation.page, page)
            }
        }
    }

    func testOverlayCreatesAndClosesPanelsOnActualConnectedScreens() async throws {
        try await withFixture { model, _, _ in
            for scope in DisplayScope.allCases {
                model.update { $0.style = .overlay; $0.displayScope = scope }
                model.action { $0.startNow(.short, now: Date()) }
                let openPanels = self.panels
                XCTAssertEqual(openPanels.count, scope == .all ? NSScreen.screens.count : 1)
                for panel in openPanels {
                    XCTAssertEqual(panel.level, .screenSaver)
                    XCTAssertTrue(NSScreen.screens.contains { $0.frame == panel.frame })
                }
                model.action { $0.finish(now: Date()) }
                XCTAssertTrue(openPanels.allSatisfy { !$0.isVisible })
            }
        }
    }

    /// Move the real pointer to each connected display; restore it after the test.
    @MainActor private func onEveryConnectedDisplay(_ body: (NSScreen) async throws -> Void) async throws {
        guard NSScreen.screens.count >= 2 else {
            throw XCTSkip("Requires the user's physically connected second display")
        }
        let original = CGEvent(source: nil)!.location
        defer { CGWarpMouseCursorPosition(original) }
        for screen in NSScreen.screens {
            let number = try XCTUnwrap(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            let bounds = CGDisplayBounds(number.uint32Value)
            XCTAssertEqual(CGWarpMouseCursorPosition(CGPoint(x: bounds.midX, y: bounds.midY)), .success)
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertTrue(screen.frame.contains(NSEvent.mouseLocation), "Real pointer must be on \(screen.localizedName)")
            try await body(screen)
        }
    }

    func testTwoDisplaysCurrentScopeFollowsRealPointer() async throws {
        try await withFixture { model, _, _ in
            model.update { $0.style = .overlay; $0.displayScope = .current }
            try await self.onEveryConnectedDisplay { screen in
                model.action { $0.startNow(.short, now: Date()) }
                let panel = try XCTUnwrap(self.panels.first)
                XCTAssertEqual(self.panels.count, 1)
                XCTAssertEqual(panel.frame, screen.frame)
                XCTAssertEqual(panel.backingScaleFactor, screen.backingScaleFactor)
                try await Task.sleep(nanoseconds: 150_000_000)
                XCTAssertTrue(self.press(try self.button(named: L10n.text("rest.end"), in: panel)))
                XCTAssertTrue(self.panels.isEmpty)
                XCTAssertFalse(model.engine.isResting)
            }
        }
    }

    func testTwoDisplaysAllScopeHasActionsOnlyOnPointerDisplay() async throws {
        try await withFixture { model, _, _ in
            model.update { $0.style = .overlay; $0.displayScope = .all; $0.breakStartMode = .manual }
            try await self.onEveryConnectedDisplay { screen in
                model.action { $0.startNow(.short, now: Date()) }
                let open = self.panels
                XCTAssertEqual(open.count, NSScreen.screens.count)
                try await Task.sleep(nanoseconds: 150_000_000)
                for panel in open {
                    XCTAssertEqual(self.findButton(named: L10n.text("rest.end"), in: panel) != nil, panel.frame == screen.frame,
                                   "Only the pointer display may have action buttons")
                    XCTAssertEqual(panel.backingScaleFactor, panel.screen?.backingScaleFactor)
                }
                let primary = try XCTUnwrap(open.first { $0.frame == screen.frame })
                XCTAssertTrue(self.press(try self.button(named: L10n.text("rest.end"), in: primary)))
                XCTAssertTrue(open.allSatisfy { !$0.isVisible })
                XCTAssertEqual(model.saved.records.filter { $0.outcome == .ended }.count,
                               NSScreen.screens.first == screen ? 1 : 2)
            }
        }
    }

    func testTwoDisplaysSecondaryEscapeClosesEveryOverlay() async throws {
        try await withFixture { model, _, _ in
            model.update { $0.style = .overlay; $0.displayScope = .all }
            try await self.onEveryConnectedDisplay { screen in
                model.action { $0.startNow(.long, now: Date()) }
                let open = self.panels
                let secondary = try XCTUnwrap(open.first { $0.frame != screen.frame })
                secondary.cancelOperation(nil)
                XCTAssertTrue(open.allSatisfy { !$0.isVisible })
                XCTAssertFalse(model.engine.isResting)
            }
        }
    }

    func testTwoDisplaysGentleCardsFitCurrentVisibleFrameAtEverySize() async throws {
        try await withFixture { model, _, _ in
            model.update { $0.style = .gentle; $0.displayScope = .all }
            try await self.onEveryConnectedDisplay { screen in
                for size in GentleReminderSize.allCases {
                    model.update { $0.gentleReminderSize = size }
                    model.action { $0.startNow(.short, now: Date()) }
                    let panel = try XCTUnwrap(self.panels.first)
                    XCTAssertEqual(self.panels.count, 1)
                    XCTAssertTrue(screen.visibleFrame.contains(panel.frame), "\(size) card must fit \(screen.localizedName)")
                    XCTAssertEqual(panel.frame.width, GentleCardLayout(size: size).width, accuracy: 1)
                    XCTAssertEqual(panel.backingScaleFactor, screen.backingScaleFactor)
                    panel.cancelOperation(nil)
                    XCTAssertTrue(self.panels.isEmpty)
                }
            }
        }
    }

    func testTwoDisplaysScreenChangeRebuildKeepsReminderAndStatistics() async throws {
        try await withFixture { model, _, _ in
            model.update { $0.style = .overlay; $0.displayScope = .all }
            try await self.onEveryConnectedDisplay { _ in
                model.action { $0.startNow(.long, now: Date()) }
                model.engine.tick(seconds: 7, now: Date()); model.consume()
                let old = self.panels
                let id = model.engine.reminder?.id
                let elapsed = model.engine.reminder?.elapsed
                let records = model.saved.records.map(\.id)
                // Exercises the observer against the two real displays. This is
                // a synthetic notification, not evidence of cable hot-plug.
                NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
                XCTAssertTrue(old.allSatisfy { !$0.isVisible })
                XCTAssertEqual(self.panels.count, NSScreen.screens.count)
                XCTAssertEqual(model.engine.reminder?.id, id)
                XCTAssertEqual(model.engine.reminder?.elapsed, elapsed)
                XCTAssertEqual(model.saved.records.map(\.id), records)
                model.action { $0.finish(now: Date()) }
            }
        }
    }

    func testPreviewEscapeAndAutomaticTimeoutDoNotChangeStatistics() async throws {
        try await withFixture { model, windows, _ in
            let before = model.saved.records.map(\.id)
            windows.preview()
            let panel = try XCTUnwrap(self.panels.first)
            panel.cancelOperation(nil)
            XCTAssertFalse(panel.isVisible)
            XCTAssertNil(model.engine.reminder)
            windows.preview()
            let timedPanel = try XCTUnwrap(self.panels.first)
            try await Task.sleep(nanoseconds: 5_300_000_000)
            XCTAssertFalse(timedPanel.isVisible)
            XCTAssertNil(model.engine.reminder)
            XCTAssertEqual(model.saved.records.map(\.id), before)
        }
    }

    func testOldPreviewTimeoutCannotCloseARealReminder() async throws {
        try await withFixture { model, windows, _ in
            windows.preview()
            model.action { $0.startNow(.long, now: Date()) }
            let realPanel = try XCTUnwrap(self.panels.first)
            let id = model.engine.reminder?.id
            try await Task.sleep(nanoseconds: 5_300_000_000)
            XCTAssertTrue(realPanel.isVisible)
            XCTAssertTrue(model.engine.isResting)
            XCTAssertEqual(model.engine.reminder?.id, id)
        }
    }

    func testWorkspaceSleepAndSessionNotificationsWaitForEveryReturnReason() async throws {
        try await withFixture { model, _, _ in
            model.begin()
            model.action { $0.startNow(.long, now: Date()) }
            let panel = try XCTUnwrap(self.panels.first)
            let center = NSWorkspace.shared.notificationCenter
            center.post(name: NSWorkspace.willSleepNotification, object: nil)
            center.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
            XCTAssertTrue(model.engine.away)
            XCTAssertFalse(panel.isVisible)
            center.post(name: NSWorkspace.didWakeNotification, object: nil)
            XCTAssertTrue(model.engine.away, "Session-away still remains after power wake")
            center.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
            XCTAssertFalse(model.engine.away)
            XCTAssertEqual(model.saved.records.filter { $0.outcome == .interrupted }.count, 1)
        }
    }

    func testNotificationFallbackShowsAndClosesANativeWarningPanel() async throws {
        try await withFixture { model, windows, _ in
            XCTAssertEqual(model.notificationStatus, "permission.bundle")
            var fallbackCalled = false
            model.notifyWarning(.short) { fallbackCalled = true }
            XCTAssertTrue(fallbackCalled)
            windows.apply([.warning(.short)])
            let warning = try XCTUnwrap(self.panels.first)
            XCTAssertTrue(warning.isVisible)
            windows.apply([.hide])
            XCTAssertFalse(warning.isVisible)
        }
    }

    func testThemeLanguagePersistenceAndClearRecordsUseOnlyInjectedStore() async throws {
        try await withFixture { model, _, directory in
            model.update { $0.theme = .dark; $0.language = "ja" }
            XCTAssertEqual(model.interfaceLanguage.lowercased(), "ja")
            XCTAssertEqual(NSApp.appearance?.name, .darkAqua)
            model.action { $0.startNow(.short, now: Date()); $0.skip(now: Date()) }
            XCTAssertFalse(model.saved.records.isEmpty)
            let settings = model.settings
            model.clearRecords()
            let loaded = model.store.load()
            XCTAssertTrue(loaded.records.isEmpty)
            XCTAssertEqual(loaded.settings, settings)
            XCTAssertEqual(model.store.url.deletingLastPathComponent().path, directory.path)
        }
    }

    func testScheduleTransitionDoesNotLeaveAnOrphanedRealPanel() async throws {
        try await withFixture { model, _, _ in
            var s = model.settings; s.restPlan = .preset(.fiftyTen)
            s.scheduleEnabled = true; s.weekdays = [2]
            model.engine.updateSettings(s)
            let calendar = Calendar.current
            let opening = calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 9))!
            model.engine.tick(seconds: 0, now: opening.addingTimeInterval(-20)); model.consume()
            model.action { $0.startNow(.short, now: opening.addingTimeInterval(-20)) }
            let panel = try XCTUnwrap(self.panels.first)
            model.engine.tick(seconds: 10, now: opening.addingTimeInterval(-10)); model.consume()
            model.engine.tick(seconds: 10, now: opening); model.consume()
            XCTAssertTrue(model.engine.isResting || !panel.isVisible,
                          "AUDIT-01: cancelling the rest must also close its real NSPanel")
        }
    }
}
