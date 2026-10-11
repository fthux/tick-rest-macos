import AppKit
import SwiftUI
import XCTest
import TickRestCore
@testable import TickRestApp

extension AppIntegrationTests {
    @MainActor private func assertSettingsMinimum(_ window: NSWindow, file: StaticString = #filePath, line: UInt = #line) {
        // AppKit may add titlebar/toolbar height to the content minimum.
        XCTAssertGreaterThanOrEqual(window.minSize.width, 720, file: file, line: line)
        XCTAssertGreaterThanOrEqual(window.minSize.height, 540, file: file, line: line)
        XCTAssertGreaterThanOrEqual(window.contentMinSize.width, 720, file: file, line: line)
        XCTAssertGreaterThanOrEqual(window.contentMinSize.height, 540, file: file, line: line)
    }
    @MainActor private func elements(in root: NSObject) -> [NSObject] {
        var result: [NSObject] = []; var pending = [root]; var visited: Set<ObjectIdentifier> = []
        while let element = pending.popLast() {
            guard visited.insert(ObjectIdentifier(element)).inserted else { continue }
            result.append(element)
            pending += (accessibilityValue(element, "accessibilityChildren") as? [NSObject]) ?? []
        }
        return result
    }

    @MainActor private func increment(_ element: NSObject, direction: Bool = true) -> Bool {
        let selector = NSSelectorFromString(direction ? "accessibilityPerformIncrement" : "accessibilityPerformDecrement")
        guard element.responds(to: selector) else { return false }
        typealias Action = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(element.method(for: selector), to: Action.self)(element, selector)
    }
    @MainActor private func field<T>(_ name: String, of object: Any, as: T.Type = T.self) throws -> T {
        try XCTUnwrap(Mirror(reflecting: object).children.first { $0.label == name }?.value as? T,
                      "Test fixture cannot inspect \(name)")
    }

    @MainActor private func withDelegate(onboarding: Bool = true,
        _ body: @MainActor (AppDelegate, AppController, NSStatusItem, URL) async throws -> Void) async throws {
        try await withFixture { _, _, directory in
            let disk = DataStore(url: directory.appendingPathComponent("launch/state.json"))
            var data = SavedData(); data.settings.language = "en"
            data.settings.detectIdle = false; data.settings.avoidFullscreen = false
            data.settings.prewarning = 0; data.settings.onboardingComplete = onboarding
            try disk.save(data)
            let delegate = AppDelegate(store: disk, lockDirectory: directory.appendingPathComponent("lock"))
            delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
            let model: AppController = try self.field("model", of: delegate)
            let status: NSStatusItem = try self.field("status", of: delegate)
            defer {
                let coordinator: WindowCoordinator? = try? self.field("windows", of: delegate)
                coordinator?.hide(restoreFocus: false)
                for name in ["settingsWindow", "welcomeWindow"] {
                    let window: NSWindow? = try? self.field(name, of: delegate)
                    window?.close()
                }
                NotificationCenter.default.removeObserver(delegate)
                DistributedNotificationCenter.default().removeObserver(delegate)
                delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
                NSStatusBar.system.removeStatusItem(status)
            }
            try await body(delegate, model, status, directory)
        }
    }

    @MainActor private func activateMenu(_ title: String, in menu: NSMenu) throws {
        let index = menu.indexOfItem(withTitle: title)
        XCTAssertGreaterThanOrEqual(index, 0, "No real menu item named \(title)")
        guard index >= 0 else { throw NSError(domain: "MenuAudit", code: 1) }
        XCTAssertTrue(menu.item(at: index)!.isEnabled)
        menu.performActionForItem(at: index)
    }

    func testLaunchWelcomeFinishesWithoutOpeningSettingsAndManualReopenUsesOneWindow() async throws {
        try await withDelegate(onboarding: false) { delegate, model, status, _ in
            let welcome: NSWindow = try self.field("welcomeWindow", of: delegate)
            XCTAssertTrue(welcome.isVisible)
            XCTAssertFalse(welcome.styleMask.contains(.resizable))
            XCTAssertEqual(welcome.contentView!.frame.width, 580, accuracy: 1)
            for _ in 0..<2 {
                try await Task.sleep(nanoseconds: 150_000_000)
                XCTAssertTrue(self.press(try self.button(named: L10n.text("common.next"), in: welcome)))
            }
            try await Task.sleep(nanoseconds: 150_000_000)
            XCTAssertTrue(self.press(try self.button(named: L10n.text("common.back"), in: welcome)))
            try await Task.sleep(nanoseconds: 150_000_000)
            XCTAssertTrue(self.press(try self.button(named: L10n.text("common.next"), in: welcome)))
            try await Task.sleep(nanoseconds: 150_000_000)
            XCTAssertTrue(self.press(try self.button(named: L10n.text("welcome.begin"), in: welcome)))
            try await Task.sleep(nanoseconds: 200_000_000)
            XCTAssertFalse(welcome.isVisible)
            XCTAssertTrue(model.settings.onboardingComplete)
            XCTAssertTrue(model.store.load().settings.onboardingComplete)
            let automaticSettings: NSWindow? = try self.field("settingsWindow", of: delegate, as: NSWindow?.self)
            XCTAssertNil(automaticSettings)
            XCTAssertNotNil(status.button)
            let menu = try XCTUnwrap(status.menu); delegate.menuWillOpen(menu)
            try self.activateMenu(L10n.text("menu.settings"), in: menu)
            let settings: NSWindow = try self.field("settingsWindow", of: delegate)
            XCTAssertTrue(settings.isVisible)
            self.assertSettingsMinimum(settings)
            settings.close()
            XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
            let reopened: NSWindow = try self.field("settingsWindow", of: delegate)
            XCTAssertTrue(reopened === settings && reopened.isVisible)
            delegate.menuWillOpen(menu)
            try self.activateMenu(L10n.text("menu.about"), in: menu)
            let navigation: SettingsNavigation = try self.field("settingsNavigation", of: delegate)
            XCTAssertEqual(navigation.page, .about)
            XCTAssertEqual(reopened.title, SettingsPage.about.title)
        }
    }

    func testActualMenuStartEndPauseResumeAndRoundRestartActions() async throws {
        try await withDelegate { delegate, model, status, _ in
            let menu = try XCTUnwrap(status.menu)
            for kind in BreakKind.allCases {
                delegate.menuWillOpen(menu)
                try self.activateMenu(L10n.text(kind == .short ? "menu.start_short" : "menu.start_long"), in: menu)
                XCTAssertEqual(model.engine.reminder?.kind, kind)
                XCTAssertTrue(model.engine.isResting)
                delegate.menuWillOpen(menu)
                try self.activateMenu(L10n.text("menu.end"), in: menu)
                XCTAssertFalse(model.engine.isResting)
            }
            for (key, expectedSeconds) in [("menu.pause_15", 900.0), ("menu.pause_60", 3600.0), ("menu.pause_today", -1.0), ("menu.pause_indefinite", -2.0)] {
                delegate.menuWillOpen(menu)
                let submenu = try XCTUnwrap(menu.item(withTitle: L10n.text("menu.pause"))?.submenu)
                let before = Date()
                try self.activateMenu(L10n.text(key), in: submenu)
                if expectedSeconds > 0, case .until(let end) = model.engine.pause {
                    XCTAssertEqual(end.timeIntervalSince(before), expectedSeconds, accuracy: 1)
                } else if expectedSeconds == -1, case .until(let end) = model.engine.pause {
                    XCTAssertEqual(end, Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: before)))
                } else { XCTAssertEqual(model.engine.pause, .indefinite) }
                delegate.menuWillOpen(menu)
                try self.activateMenu(L10n.text("menu.resume"), in: menu)
                XCTAssertNil(model.engine.pause)
            }
            model.applyPlan(.preset(.pomodoro))
            model.engine.tick(seconds: 1500, now: Date()); model.consume()
            delegate.menuWillOpen(menu)
            try self.activateMenu(L10n.text("plan.restart_round"), in: menu)
            XCTAssertEqual(model.engine.completedRounds, 1)
            XCTAssertEqual(model.engine.remaining(.short), 1500)
            delegate.menuWillOpen(menu)
            try self.activateMenu(L10n.text("plan.restart_group"), in: menu)
            XCTAssertEqual(model.engine.completedRounds, 0)
            XCTAssertEqual(model.saved.records.filter { $0.outcome == .restarted }.count, 2)
            XCTAssertEqual(menu.item(withTitle: L10n.text("menu.settings"))?.keyEquivalent, ",")
            XCTAssertEqual(menu.item(withTitle: L10n.text("menu.quit"))?.keyEquivalent, "q")
        }
    }

    func testOpenMenuUpdatesTimeStateActionsAndEveryLanguage() async throws {
        try await withDelegate { delegate, model, status, _ in
            let menu = try XCTUnwrap(status.menu); delegate.menuWillOpen(menu)
            let oldCountdown = menu.items.map(\.title)
            model.engine.tick(seconds: 10, now: Date()); model.consume(); model.revision += 1
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertNotEqual(menu.items.map(\.title), oldCountdown)
            for language in ["en", "zh-Hans", "zh-Hant", "ja", "ko"] {
                model.update { $0.language = language }
                try await Task.sleep(nanoseconds: 100_000_000)
                // An open menu must refresh action labels too, not just its clocks.
                XCTAssertNotNil(menu.item(withTitle: L10n.text("menu.settings")), "Open menu action labels must follow \(language)")
                XCTAssertEqual(status.button?.toolTip, L10n.text("app.name") + " — " + model.stateText)
            }
            model.action { $0.startNow(.short, now: Date()) }
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertNotNil(menu.item(withTitle: L10n.text("menu.end")))
            model.engine.tick(seconds: 20, now: Date()); model.consume(); model.revision += 1
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertNotNil(menu.item(withTitle: L10n.text("menu.start_short")))
            delegate.menuDidClose(menu)
        }
    }

    func testActualToolbarToggleAndAllPageTitlesAtMinimumWindowSize() async throws {
        try await withDelegate { delegate, model, _, _ in
            delegate.openSettings()
            try await Task.sleep(nanoseconds: 300_000_000)
            let window: NSWindow = try self.field("settingsWindow", of: delegate)
            let navigation: SettingsNavigation = try self.field("settingsNavigation", of: delegate)
            let toolbar = try XCTUnwrap(window.toolbar)
            let toggle = try XCTUnwrap(toolbar.items.first { $0.itemIdentifier.rawValue == AppIdentity.identifier("sidebar") })
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(toggle.action), to: toggle.target, from: toggle))
            XCTAssertEqual(navigation.columnVisibility, .detailOnly)
            XCTAssertEqual(toggle.label, L10n.text("settings.sidebar.show"))
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(toggle.action), to: toggle.target, from: toggle))
            XCTAssertEqual(navigation.columnVisibility, .all)
            self.assertSettingsMinimum(window)
            print("AUDIT environment: connected screens=\(NSScreen.screens.count), settings minSize=\(window.minSize)")
            window.setContentSize(window.minSize)
            try await Task.sleep(nanoseconds: 200_000_000)
            let content = try XCTUnwrap(window.contentView)
            content.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let output = project.appendingPathComponent(".build/native-ui-audit/settings-actual-minimum.png")
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output)
            print("AUDIT minimum resize: content=\(content.bounds.size), frame=\(window.frame.size)")
            for page in SettingsPage.allCases {
                navigation.page = page
                try await Task.sleep(nanoseconds: 100_000_000)
                self.assertSettingsMinimum(window)
                XCTAssertEqual(window.title, page.title)
                let title: NSTextField = try self.field("settingsTitleField", of: delegate)
                XCTAssertEqual(title.stringValue, page.title)
                XCTAssertTrue(window.toolbar === toolbar)
                XCTAssertTrue(self.containsText(page.title, in: window))
            }
            model.update { $0.language = "ja" }
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertEqual(toggle.label, L10n.text("settings.sidebar.hide"))
        }
    }

    func testControllerInvalidUpdateAndSaveFailureShowRecoverableErrors() async throws {
        try await withFixture { model, _, directory in
            let before = model.settings
            let bytes = try Data(contentsOf: model.store.url)
            model.update { $0.shortDuration = -1 }
            XCTAssertEqual(model.settings, before)
            XCTAssertEqual(try Data(contentsOf: model.store.url), bytes)
            XCTAssertNotNil(model.errorMessage)
            model.dismissError(); XCTAssertNil(model.errorMessage)
            let blocker = directory.appendingPathComponent("file-not-directory")
            try Data("blocker".utf8).write(to: blocker)
            let other = AppController(store: DataStore(url: blocker.appendingPathComponent("state.json")))
            other.persist()
            XCTAssertEqual(other.errorMessage, L10n.text("error.save"))
            XCTAssertEqual(try Data(contentsOf: blocker), Data("blocker".utf8))
            other.dismissError(); XCTAssertNil(other.errorMessage)
            other.action { $0.startNow(.short, now: Date()); $0.skip(now: Date()) }
            let records = other.saved.records
            XCTAssertFalse(records.isEmpty)
            XCTAssertFalse(other.clearRecords())
            XCTAssertEqual(other.saved.records.map(\.id), records.map(\.id))
            XCTAssertEqual(other.errorMessage, L10n.text("error.save"))
        }
    }

    func testWarningIsHiddenImmediatelyWhenFullscreenSuppressionBegins() async throws {
        try await withFixture { model, _, _ in
            model.update { $0.prewarning = 10 }
            model.engine.tick(seconds: 30, now: Date()); model.consume()
            model.engine.tick(seconds: 1160, now: Date()); model.consume()
            let warning = try XCTUnwrap(self.panels.first)
            XCTAssertTrue(warning.isVisible)
            model.engine.setSuppressed(true); model.consume()
            XCTAssertFalse(warning.isVisible, "AUDIT-07: stale local warning must close when suppression begins")
        }
    }

    func testMiniIdeaPopoverAndPostponementLimitUseRealControls() async throws {
        try await withFixture { model, _, _ in
            model.update { $0.gentleReminderSize = .mini; $0.postponeLimit = 1 }
            model.action { $0.startNow(.short, now: Date()) }
            let panel = try XCTUnwrap(self.panels.first)
            try await Task.sleep(nanoseconds: 150_000_000)
            XCTAssertTrue(self.press(try self.button(named: L10n.text("rest.idea"), in: panel)))
            try await Task.sleep(nanoseconds: 150_000_000)
            let idea = try XCTUnwrap(model.engine.reminder?.idea)
            XCTAssertTrue(NSApp.windows.contains { $0.isVisible && self.containsText(idea, in: $0) })
            XCTAssertTrue(self.press(try self.button(named: L10n.text("rest.defer", 2), in: panel)))
            XCTAssertFalse(panel.isVisible)
            model.engine.tick(seconds: 120, now: Date()); model.engine.tick(seconds: 1, now: Date()); model.consume()
            let returned = try XCTUnwrap(self.panels.first)
            try await Task.sleep(nanoseconds: 150_000_000)
            let postpone = try self.button(named: L10n.text("rest.defer", 2), in: returned)
            XCTAssertEqual(self.isEnabled(postpone), false)
            XCTAssertTrue(self.containsText(L10n.text("rest.defer_limit"), in: returned))
        }
    }

    func testClearRecordsDialogCancelAndConfirmPreservePreferences() async throws {
        try await withFixture { model, _, _ in
            model.action { $0.startNow(.short, now: Date()); $0.skip(now: Date()) }
            let ids = model.saved.records.map(\.id); let preferences = model.settings
            let navigation = SettingsNavigation(); navigation.page = .privacy
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 640),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: model, navigation: navigation))
            window.makeKeyAndOrderFront(nil); defer { window.close() }
            try await Task.sleep(nanoseconds: 200_000_000)
            XCTAssertTrue(self.press(try self.button(named: L10n.text("data.clear"), in: window)))
            try await Task.sleep(nanoseconds: 200_000_000)
            let dialog = try XCTUnwrap(window.attachedSheet)
            _ = self.press(try self.button(named: L10n.text("common.cancel"), in: dialog))
            try await Task.sleep(nanoseconds: 200_000_000)
            XCTAssertNil(window.attachedSheet)
            XCTAssertEqual(model.saved.records.map(\.id), ids)
            XCTAssertTrue(self.press(try self.button(named: L10n.text("data.clear"), in: window)))
            try await Task.sleep(nanoseconds: 200_000_000)
            let confirmation = try XCTUnwrap(window.attachedSheet)
            _ = self.press(try self.button(named: L10n.text("data.clear"), in: confirmation))
            try await Task.sleep(nanoseconds: 200_000_000)
            XCTAssertNil(window.attachedSheet)
            XCTAssertTrue(model.saved.records.isEmpty)
            XCTAssertTrue(model.store.load().records.isEmpty)
            XCTAssertEqual(model.settings, preferences)
            XCTAssertTrue(window.isVisible)
            XCTAssertTrue(self.containsText(L10n.text("data.clear_success"), in: window))
        }
    }

    func testPlanDraftIncrementCancelApplyAndPendingCancellationUseActualButtons() async throws {
        try await withFixture { model, _, _ in
            let navigation = SettingsNavigation(); navigation.page = .rhythm
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 900),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: model, navigation: navigation))
            window.orderFrontRegardless(); defer { window.close() }
            try await Task.sleep(nanoseconds: 200_000_000)
            let original = model.settings.restPlan
            XCTAssertEqual(self.isEnabled(try self.button(named: L10n.text("plan.apply"), in: window)), false)
            let steppers = self.elements(in: window).filter {
                self.accessibilityValue($0, "accessibilityRole") as? String == "AXIncrementor"
            }
            let stepper = try XCTUnwrap(steppers.first)
            _ = self.increment(stepper)
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertEqual(self.isEnabled(try self.button(named: L10n.text("plan.apply"), in: window)), true)
            XCTAssertEqual(model.settings.restPlan, original, "Editing a draft must not apply it")
            XCTAssertEqual(model.store.load().settings.restPlan, original)
            XCTAssertTrue(self.press(try self.button(named: L10n.text("common.cancel"), in: window)))
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertEqual(self.isEnabled(try self.button(named: L10n.text("plan.apply"), in: window)), false)
            _ = self.increment(stepper)
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertEqual(self.isEnabled(try self.button(named: L10n.text("plan.apply"), in: window)), true)
            XCTAssertTrue(self.press(try self.button(named: L10n.text("plan.apply"), in: window)))
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertNotEqual(model.settings.restPlan, original)
            XCTAssertEqual(model.settings.planID, .custom)
            XCTAssertEqual(model.store.load().settings, model.settings)
            model.action { $0.startNow(.short, now: Date()) }
            _ = self.increment(stepper)
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertEqual(self.isEnabled(try self.button(named: L10n.text("plan.apply"), in: window)), true)
            XCTAssertTrue(self.press(try self.button(named: L10n.text("plan.apply"), in: window)))
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertNotNil(model.engine.pendingPlan)
            XCTAssertTrue(self.press(try self.button(named: L10n.text("plan.cancel_pending"), in: window)))
            XCTAssertNil(model.engine.pendingPlan)
        }
    }
}
