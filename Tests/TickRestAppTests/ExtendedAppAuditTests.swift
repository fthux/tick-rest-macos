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

    func testActualMenuStartSkipPauseResumeAndRoundRestartActions() async throws {
        try await withDelegate { delegate, model, status, _ in
            let menu = try XCTUnwrap(status.menu)
            for kind in BreakKind.allCases {
                delegate.menuWillOpen(menu)
                try self.activateMenu(L10n.text(kind == .short ? "menu.start_short" : "menu.start_long"), in: menu)
                XCTAssertEqual(model.engine.reminder?.kind, kind)
                XCTAssertTrue(model.engine.isResting)
                delegate.menuWillOpen(menu)
                try self.activateMenu(L10n.text("rest.skip"), in: menu)
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

    func testNormalFocusMenuCombinesRoundAndCountdownWhileKeepingPauseVisible() async throws {
        try await withDelegate { delegate, model, status, _ in
            let timer: Timer? = try self.field("timer", of: model, as: Timer?.self)
            timer?.invalidate() // Advance time explicitly, independently of the live scheduler.
            model.applyPlan(.preset(.pomodoro))
            let menu = try XCTUnwrap(status.menu)
            func information() -> [NSMenuItem] {
                Array(menu.items.prefix { !$0.isSeparatorItem }).filter { !$0.isHidden }
            }
            for language in ["en", "zh-Hans", "zh-Hant", "ja", "ko"] {
                model.update { $0.language = language }
                delegate.menuWillOpen(menu)
                XCTAssertEqual(information().map(\.title), [L10n.text("plan.focus_remaining", 1, 4,
                    L10n.clock(model.engine.remaining(.short)))])
                model.action { $0.tick(seconds: 10, now: Date()) }
                try await Task.sleep(nanoseconds: 100_000_000)
                XCTAssertEqual(information().map(\.title), [L10n.text("plan.focus_remaining", 1, 4,
                    L10n.clock(model.engine.remaining(.short)))])
                model.action { $0.setPause(.indefinite, now: Date()) }
                try await Task.sleep(nanoseconds: 100_000_000)
                XCTAssertEqual(information().count, 2)
                XCTAssertEqual(information().first?.title, L10n.text("state.paused"))
                model.resume()
                try await Task.sleep(nanoseconds: 100_000_000)
                XCTAssertEqual(information().map(\.title), [L10n.text("plan.focus_remaining", 1, 4,
                    L10n.clock(model.engine.remaining(.short)))])
                delegate.menuDidClose(menu)
            }
            for (plan, count) in [(RestPlanID.tickrest, 3), (.fiftyTen, 2)] {
                model.applyPlan(.preset(plan))
                delegate.menuWillOpen(menu)
                XCTAssertEqual(information().count, count)
                XCTAssertEqual(information().first?.title, L10n.text("state.running"))
                delegate.menuDidClose(menu)
            }
        }
    }

    func testRoundMenuShowsFocusOnceAfterEarlyEndAndUpdatesWhileOpen() async throws {
        try await withDelegate { delegate, model, status, _ in
            model.applyPlan(.preset(.pomodoro))
            model.action { engine in
                engine.tick(seconds: 1500, now: Date())
                engine.startNow(.short, now: Date())
                engine.finish(now: Date())
            }
            XCTAssertNotNil(model.engine.roundRestKind)
            XCTAssertGreaterThan(model.engine.remaining(.short), 0)
            let menu = try XCTUnwrap(status.menu)
            for language in ["en", "zh-Hans", "zh-Hant", "ja", "ko"] {
                model.update { $0.language = language }
                delegate.menuWillOpen(menu)
                let focus = L10n.text("plan.focus_state", 1, 4)
                XCTAssertEqual(menu.items.filter { !$0.isHidden && $0.title == focus }.count, 1)
                XCTAssertTrue(menu.items.contains {
                    !$0.isHidden && $0.title == ReminderDisplay(engine: model.engine).countdownText(for: .short)
                })
                model.action { $0.setPause(.indefinite, now: Date()) }
                try await Task.sleep(nanoseconds: 100_000_000)
                XCTAssertEqual(menu.items.first?.title, L10n.text("state.paused"))
                XCTAssertEqual(menu.items.filter { !$0.isHidden && $0.title == focus }.count, 1)
                model.resume()
                try await Task.sleep(nanoseconds: 100_000_000)
                XCTAssertEqual(menu.items.first?.title, focus)
                XCTAssertEqual(menu.items.filter { !$0.isHidden && $0.title == focus }.count, 1)
                delegate.menuDidClose(menu)
            }
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
            XCTAssertNotNil(menu.item(withTitle: L10n.text("rest.skip")))
            model.engine.tick(seconds: 20, now: Date()); model.consume(); model.revision += 1
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertNotNil(menu.item(withTitle: L10n.text("menu.start_short")))
            delegate.menuDidClose(menu)
        }
    }

    func testSettingsSidebarTogglePreservesWindowFrameAfterFreshLaunch() async throws {
        // Each delegate creates a fresh settings host, as quitting and relaunching does.
        for _ in 0..<2 {
            try await withDelegate { delegate, _, _, _ in
                delegate.openSettings()
                try await Task.sleep(nanoseconds: 400_000_000)
                let window: NSWindow = try self.field("settingsWindow", of: delegate)
                let navigation: SettingsNavigation = try self.field("settingsNavigation", of: delegate)
                let toggle = try XCTUnwrap(window.toolbar?.items.first {
                    $0.itemIdentifier.rawValue == AppIdentity.identifier("sidebar")
                })
                let button = try XCTUnwrap(toggle.view as? NSButton)
                for width: CGFloat in [window.frame.width, 720, 1000] {
                    var frame = window.frame
                    frame.size.width = width
                    window.setFrame(frame, display: true)
                    try await Task.sleep(nanoseconds: 300_000_000)
                    let original = window.frame
                    for _ in 0..<3 {
                        for visibility: NavigationSplitViewVisibility in [.detailOnly, .all] {
                            button.performClick(nil)
                            try await Task.sleep(nanoseconds: 400_000_000)
                            XCTAssertEqual(navigation.columnVisibility, visibility)
                            XCTAssertTrue(window.toolbar?.visibleItems?.contains { $0 === toggle } == true,
                                          "The sidebar control must stay visible in both states")
                            let split: NSSplitViewController = try self.field("settingsSplitController", of: delegate)
                            XCTAssertEqual(split.splitViewItems.first?.isCollapsed, visibility == .detailOnly)
                            if visibility == .all {
                                let buttonFrame = button.convert(button.bounds, to: nil)
                                let sidebarWidth = try XCTUnwrap(split.splitView.arrangedSubviews.first).frame.width
                                XCTAssertLessThanOrEqual(buttonFrame.maxX, sidebarWidth)
                                XCTAssertGreaterThanOrEqual(buttonFrame.minX, sidebarWidth - 50)
                                XCTAssertGreaterThan(buttonFrame.width, 0)
                            }
                            self.assertSettingsMinimum(window)
                            XCTAssertEqual(window.frame.width, original.width, accuracy: 1)
                            XCTAssertEqual(window.frame.height, original.height, accuracy: 1)
                            XCTAssertEqual(window.frame.minX, original.minX, accuracy: 1)
                            XCTAssertEqual(window.frame.maxY, original.maxY, accuracy: 1)
                        }
                    }
                }
            }
        }
    }

    func testSidebarAnimationKeepsWindowStableAndSettlesAfterRapidToggle() async throws {
        try await withDelegate { delegate, _, _, _ in
            delegate.openSettings()
            try await Task.sleep(nanoseconds: 400_000_000)
            let window: NSWindow = try self.field("settingsWindow", of: delegate)
            let navigation: SettingsNavigation = try self.field("settingsNavigation", of: delegate)
            let split: NSSplitViewController = try self.field("settingsSplitController", of: delegate)
            let sidebar = try XCTUnwrap(split.splitViewItems.first)
            let toggle = try XCTUnwrap(window.toolbar?.items.first {
                $0.itemIdentifier.rawValue == AppIdentity.identifier("sidebar")
            })
            let action = try XCTUnwrap(toggle.action)
            let original = window.frame
            let expandedX = try XCTUnwrap(split.splitView.arrangedSubviews.last).frame.minX
            var samples: [[String: Any]] = []
            for page in [SettingsPage.general, .appearance, .overview] {
                navigation.page = page
                try await Task.sleep(nanoseconds: 200_000_000)
                for visibility: NavigationSplitViewVisibility in [.detailOnly, .all] {
                    let start = ProcessInfo.processInfo.systemUptime
                    var positions: [CGFloat] = []
                    XCTAssertTrue(NSApp.sendAction(action, to: toggle.target, from: toggle))
                    for _ in 0..<30 {
                        try await Task.sleep(nanoseconds: 16_000_000)
                        let position = try XCTUnwrap(split.splitView.arrangedSubviews.last).frame.minX
                        let hostX = sidebar.viewController.view.convert(sidebar.viewController.view.bounds, to: nil).minX
                        positions.append(position)
                        samples.append(["page": page.rawValue, "expanded": visibility == .all,
                            "elapsed": ProcessInfo.processInfo.systemUptime - start,
                            "sidebarContentX": hostX,
                            "splitWidth": split.splitView.frame.width,
                            "detailX": split.splitView.arrangedSubviews.last?.frame.minX ?? -1,
                            "detailWidth": split.splitView.arrangedSubviews.last?.frame.width ?? -1,
                            "sidebarWidth": split.splitView.arrangedSubviews.first?.frame.width ?? -1])
                        XCTAssertEqual(window.frame.width, original.width, accuracy: 1)
                        XCTAssertEqual(window.frame.minX, original.minX, accuracy: 1)
                        XCTAssertEqual(hostX, 0, accuracy: 1, "Sidebar content must stay anchored to the window's left edge")
                    }
                    XCTAssertEqual(sidebar.isCollapsed, visibility == .detailOnly)
                    XCTAssertEqual(navigation.columnVisibility, visibility)
                    XCTAssertEqual(try XCTUnwrap(positions.last), visibility == .all ? expandedX : 0, accuracy: 1)
                    if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                        // Keep an actual transition, and reject a layout reversal or snap.
                        XCTAssertGreaterThan(positions.filter { $0 > 1 && $0 < expandedX - 1 }.count, 1)
                        for (previous, next) in zip(positions, positions.dropFirst()) {
                            if visibility == .all { XCTAssertGreaterThanOrEqual(next + 1, previous) }
                            else { XCTAssertLessThanOrEqual(next, previous + 1) }
                        }
                    }
                }
            }
            // Reverse direction before the first animation finishes.
            for _ in 0..<4 {
                XCTAssertTrue(NSApp.sendAction(action, to: toggle.target, from: toggle))
                try await Task.sleep(nanoseconds: 60_000_000)
            }
            try await Task.sleep(nanoseconds: 400_000_000)
            XCTAssertEqual(navigation.columnVisibility, .all)
            XCTAssertFalse(sidebar.isCollapsed)
            XCTAssertEqual(window.frame.width, original.width, accuracy: 1)
            XCTAssertTrue(window.toolbar?.items.contains { $0 === toggle } == true)
            let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let output = project.appendingPathComponent(".build/native-ui-audit/sidebar-motion.json")
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys]).write(to: output)
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
            XCTAssertTrue(toolbar.visibleItems?.contains { $0 === toggle } == true,
                          "The sidebar button must be visible, not just present in the toolbar")
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(toggle.action), to: toggle.target, from: toggle))
            XCTAssertEqual(navigation.columnVisibility, .detailOnly)
            XCTAssertEqual(toggle.label, L10n.text("settings.sidebar.show"))
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(toggle.action), to: toggle.target, from: toggle))
            XCTAssertEqual(navigation.columnVisibility, .all)
            self.assertSettingsMinimum(window)
            print("AUDIT environment: connected screens=\(NSScreen.screens.count), settings minSize=\(window.minSize)")
            window.setContentSize(window.minSize)
            try await Task.sleep(nanoseconds: 200_000_000)
            XCTAssertTrue(toolbar.visibleItems?.contains { $0 === toggle } == true)
            let content = try XCTUnwrap(window.contentView)
            content.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let output = project.appendingPathComponent(".build/native-ui-audit/settings-actual-minimum.png")
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output)
            let frameView = try XCTUnwrap(content.superview)
            let windowBitmap = try XCTUnwrap(frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds))
            frameView.cacheDisplay(in: frameView.bounds, to: windowBitmap)
            try XCTUnwrap(windowBitmap.representation(using: .png, properties: [:])).write(
                to: output.deletingLastPathComponent().appendingPathComponent("settings-toolbar-placement.png"))
            print("AUDIT minimum resize: content=\(content.bounds.size), frame=\(window.frame.size)")
            for page in SettingsPage.allCases {
                navigation.page = page
                try await Task.sleep(nanoseconds: 100_000_000)
                self.assertSettingsMinimum(window)
                XCTAssertEqual(window.title, page.title)
                let title: NSTextField = try self.field("settingsTitleField", of: delegate)
                XCTAssertEqual(title.stringValue, page.title)
                XCTAssertTrue(window.toolbar === toolbar)
                XCTAssertTrue(toolbar.visibleItems?.contains { $0 === toggle } == true)
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
    func testSettingsTitlebarKeepsItsBackgroundWhenInactive() async throws {
        try await withDelegate { delegate, model, _, _ in
            model.update { $0.theme = .light }
            delegate.openSettings()
            try await Task.sleep(nanoseconds: 400_000_000)
            let window: NSWindow = try self.field("settingsWindow", of: delegate)
            XCTAssertTrue(window.titlebarAppearsTransparent)
            let expected = try XCTUnwrap(window.backgroundColor.usingColorSpace(.sRGB))
            XCTAssertEqual(expected.redComponent, 234 / 255, accuracy: 0.001)
            XCTAssertEqual(expected.greenComponent, 235 / 255, accuracy: 0.001)
            XCTAssertEqual(expected.blueComponent, 236 / 255, accuracy: 0.001)
            let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                                 styleMask: [.titled], backing: .buffered, defer: false)
            other.isReleasedWhenClosed = false
            defer { other.close() }
            other.makeKeyAndOrderFront(nil)
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertFalse(window.isKeyWindow)
            XCTAssertTrue(window.titlebarAppearsTransparent)
            XCTAssertEqual(window.backgroundColor.usingColorSpace(.sRGB), expected)
        }
    }

    func testSettingsSeparatorTracksDetailScrollAndPageChanges() async throws {
        try await withDelegate { delegate, _, _, _ in
            delegate.openSettings()
            try await Task.sleep(nanoseconds: 400_000_000)
            let window: NSWindow = try self.field("settingsWindow", of: delegate)
            @MainActor func snapshot(_ name: String) throws -> NSBitmapImageRep {
                let frame = try XCTUnwrap(window.contentView?.superview)
                let bitmap = try XCTUnwrap(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
                frame.cacheDisplay(in: frame.bounds, to: bitmap)
                let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                let output = project.appendingPathComponent(".build/settings-review")
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
                return bitmap
            }
            let navigation: SettingsNavigation = try self.field("settingsNavigation", of: delegate)
            let split: NSSplitViewController = try self.field("settingsSplitController", of: delegate)
            func scrollViews(_ view: NSView) -> [NSScrollView] {
                if let scroll = view as? NSScrollView { return [scroll] }
                return view.subviews.flatMap(scrollViews)
            }
            let detail = try XCTUnwrap(split.splitView.arrangedSubviews.last)
            let scroll = try XCTUnwrap(scrollViews(detail).first)
            let document = try XCTUnwrap(scroll.documentView)
            XCTAssertFalse(navigation.detailScrolled)
            XCTAssertEqual(window.titlebarSeparatorStyle, .none)
            let topBitmap = try snapshot("scroll-top")
            let top = document.isFlipped ? document.bounds.minY : document.bounds.maxY - scroll.contentView.bounds.height
            let down = top + (document.isFlipped ? 80 : -80)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: down))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertTrue(navigation.detailScrolled)
            XCTAssertEqual(window.titlebarSeparatorStyle, .line)
            let downBitmap = try snapshot("scroll-down")
            let frame = try XCTUnwrap(window.contentView?.superview)
            let boundaryY = Int((frame.bounds.height - window.contentLayoutRect.maxY) * window.backingScaleFactor)
            let sampleX = topBitmap.pixelsWide - 60
            let topColor = try XCTUnwrap(topBitmap.colorAt(x: sampleX, y: boundaryY)?.usingColorSpace(.sRGB))
            let downColor = try XCTUnwrap(downBitmap.colorAt(x: sampleX, y: boundaryY)?.usingColorSpace(.sRGB))
            XCTAssertLessThan(downColor.redComponent, topColor.redComponent - 0.04,
                              "Scrolling must draw an actual line at the titlebar boundary")
            delegate.openSettings()
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertEqual(split.splitViewItems.last?.titlebarSeparatorStyle, .line)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: top))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertFalse(navigation.detailScrolled)
            XCTAssertEqual(window.titlebarSeparatorStyle, .none)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: down))
            scroll.reflectScrolledClipView(scroll.contentView)
            navigation.page = .privacy
            try await Task.sleep(nanoseconds: 400_000_000)
            XCTAssertFalse(navigation.detailScrolled)
            XCTAssertEqual(window.titlebarSeparatorStyle, .none)
        }
    }

    func testGentleAppearanceScrollsAsOnePageAtMinimumSize() async throws {
        try await withDelegate { delegate, model, _, _ in
            model.update { $0.style = .gentle; $0.language = "zh-Hans" }
            let navigation: SettingsNavigation = try self.field("settingsNavigation", of: delegate)
            navigation.page = .appearance
            delegate.openSettings()
            try await Task.sleep(nanoseconds: 300_000_000)
            let window: NSWindow = try self.field("settingsWindow", of: delegate)
            window.setContentSize(NSSize(width: 780, height: 580))
            try await Task.sleep(nanoseconds: 300_000_000)
            let split: NSSplitViewController = try self.field("settingsSplitController", of: delegate)
            func scrollViews(_ view: NSView) -> [NSScrollView] {
                if let scroll = view as? NSScrollView { return [scroll] }
                return view.subviews.flatMap(scrollViews)
            }
            let detail = try XCTUnwrap(split.splitView.arrangedSubviews.last)
            let scroll = try XCTUnwrap(scrollViews(detail).first)
            let document = try XCTUnwrap(scroll.documentView)
            XCTAssertEqual(scrollViews(detail).count, 1)
            XCTAssertTrue(self.containsText(L10n.text("reminder.style"), in: window.contentView!))
            XCTAssertNotNil(self.findButton(named: L10n.text("reminder.test_sound"), in: window.contentView!))
            XCTAssertGreaterThan(document.bounds.height, scroll.contentView.bounds.height)
            let bottom = document.isFlipped ? document.bounds.maxY - scroll.contentView.bounds.height : document.bounds.minY
            scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertTrue(navigation.detailScrolled)
        }
    }

    func testFullscreenSteppersAndGradientButtonsUpdateSettings() async throws {
        try await withDelegate { delegate, model, _, _ in
            model.update {
                $0.theme = .light; $0.language = "zh-Hans"; $0.style = .overlay
                $0.overlayBackground.kind = .gradient
                $0.overlayBackground.activeProtection = 0.65
            }
            let navigation: SettingsNavigation = try self.field("settingsNavigation", of: delegate)
            navigation.page = .appearance
            delegate.openSettings()
            try await Task.sleep(nanoseconds: 400_000_000)
            let window: NSWindow = try self.field("settingsWindow", of: delegate)
            window.setContentSize(NSSize(width: 920, height: 850))
            try await Task.sleep(nanoseconds: 300_000_000)
            let root = try XCTUnwrap(window.contentView)
            @MainActor func protectionStepper() throws -> NSObject {
                let title = L10n.text("background.protection_scope", L10n.text("background.type.gradient"))
                return try XCTUnwrap(self.elements(in: root).first {
                    self.accessibilityValue($0, "accessibilityRole") as? String == NSAccessibility.Role.incrementor.rawValue &&
                    self.accessibilityValue($0, "accessibilityLabel") as? String == title
                })
            }
            let percentTitle = L10n.text("background.protection_scope", L10n.text("background.type.gradient"))
            XCTAssertFalse(self.elements(in: root).contains {
                self.accessibilityValue($0, "accessibilityRole") as? String == NSAccessibility.Role.textField.rawValue &&
                self.accessibilityValue($0, "accessibilityLabel") as? String == percentTitle
            }, "Percentages must not expose an editable text field")
            _ = self.increment(try protectionStepper())
            XCTAssertEqual(model.settings.overlayBackground.activeProtection, 0.66, accuracy: 0.001)
            model.update { $0.overlayBackground.activeProtection = 0.90 }
            try await Task.sleep(nanoseconds: 100_000_000)
            _ = self.increment(try protectionStepper())
            XCTAssertEqual(model.settings.overlayBackground.activeProtection, 0.90, accuracy: 0.001)
            _ = self.increment(try protectionStepper(), direction: false)
            XCTAssertEqual(model.settings.overlayBackground.activeProtection, 0.89, accuracy: 0.001)
            let count = model.settings.overlayBackground.gradient.stops.count
            XCTAssertTrue(self.press(try self.button(named: L10n.text("background.add_stop"), in: root)))
            XCTAssertEqual(model.settings.overlayBackground.gradient.stops.count, count + 1)
            try await Task.sleep(nanoseconds: 100_000_000)
            let colors = model.settings.overlayBackground.gradient.stops.map(\.color)
            XCTAssertTrue(self.press(try self.button(named: L10n.text("background.reverse"), in: root)))
            XCTAssertEqual(model.settings.overlayBackground.gradient.stops.map(\.color), Array(colors.reversed()))
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertTrue(self.press(try self.button(named: L10n.text("background.remove_stop"), in: root)))
            XCTAssertEqual(model.settings.overlayBackground.gradient.stops.count, count)
            let frame = try XCTUnwrap(root.superview)
            let bitmap = try XCTUnwrap(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
            frame.cacheDisplay(in: frame.bounds, to: bitmap)
            let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let output = project.appendingPathComponent(".build/settings-review")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("overlay-gradient.png"))
        }
    }

    func testSwitchingFullscreenStyleKeepsSidebarPosition() async throws {
        try await withDelegate { delegate, model, _, _ in
            model.update { $0.theme = .light; $0.language = "zh-Hans" }
            delegate.openSettings()
            try await Task.sleep(nanoseconds: 400_000_000)
            let window: NSWindow = try self.field("settingsWindow", of: delegate)
            let navigation: SettingsNavigation = try self.field("settingsNavigation", of: delegate)
            let split: NSSplitViewController = try self.field("settingsSplitController", of: delegate)
            func outlineViews(_ view: NSView) -> [NSOutlineView] {
                if let outline = view as? NSOutlineView { return [outline] }
                return view.subviews.flatMap(outlineViews)
            }
            for size in [NSSize(width: 920, height: 680), NSSize(width: 780, height: 580)] {
                window.setContentSize(size)
                navigation.page = .general
                model.update { $0.style = .gentle }
                try await Task.sleep(nanoseconds: 300_000_000)
                let sidebar = try XCTUnwrap(split.splitView.arrangedSubviews.first)
                let outline = try XCTUnwrap(outlineViews(sidebar).first)
                let initial = outline.convert(outline.rect(ofRow: 0), to: nil)
                let windowFrame = window.frame
                for style in [ReminderStyle.gentle, .overlay, .gentle, .overlay] {
                    navigation.page = .appearance
                    model.update { $0.style = style }
                    try await Task.sleep(nanoseconds: 300_000_000)
                    let current = outline.convert(outline.rect(ofRow: 0), to: nil)
                    XCTAssertEqual(current.minY, initial.minY, accuracy: 0.5)
                    XCTAssertEqual(window.frame, windowFrame)
                }
            }
        }
    }

}
