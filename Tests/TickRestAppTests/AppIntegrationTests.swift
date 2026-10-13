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
    func withFixture(_ body: @MainActor (AppController, WindowCoordinator, URL) async throws -> Void) async throws {
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

    @MainActor var panels: [ReminderPanel] {
        NSApp.windows.compactMap { $0 as? ReminderPanel }.filter(\.isVisible)
    }

    @MainActor func accessibilityValue(_ object: NSObject, _ selectorName: String) -> AnyObject? {
        let selector = NSSelectorFromString(selectorName)
        if object.responds(to: selector), let value = object.perform(selector)?.takeUnretainedValue() { return value }
        // AppKit's outline-row proxies still expose the legacy attribute interface.
        let attribute: NSAccessibility.Attribute
        switch selectorName {
        case "accessibilityRole": attribute = .role
        case "accessibilityLabel": attribute = .description
        case "accessibilityTitle": attribute = .title
        case "accessibilityChildren": attribute = .children
        case "accessibilityValue": attribute = .value
        default: return nil
        }
        return object.accessibilityAttributeValue(attribute) as AnyObject?
    }

    @MainActor func findButton(named title: String, in root: NSObject) -> NSObject? {
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

    @MainActor func containsText(_ text: String, in root: NSObject) -> Bool {
        var pending: [NSObject] = [root]
        var visited: Set<ObjectIdentifier> = []
        while let element = pending.popLast() {
            guard visited.insert(ObjectIdentifier(element)).inserted else { continue }
            for selector in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"] {
                if accessibilityValue(element, selector) as? String == text { return true }
            }
            pending += (accessibilityValue(element, "accessibilityChildren") as? [NSObject]) ?? []
        }
        return false
    }

    @MainActor func button(named title: String, in root: NSObject) throws -> NSObject {
        if let found = findButton(named: title, in: root) { return found }
        XCTFail("Native accessibility tree has no button named \(title)")
        throw NSError(domain: "TickRestNativeTest", code: 1)
    }

    @MainActor func isEnabled(_ object: NSObject) -> Bool? {
        let selector = NSSelectorFromString("isAccessibilityEnabled")
        if object.responds(to: selector) {
            typealias EnabledValue = @convention(c) (AnyObject, Selector) -> Bool
            let value = unsafeBitCast(object.method(for: selector), to: EnabledValue.self)
            return value(object, selector)
        }
        return object.accessibilityAttributeValue(.enabled) as? Bool
    }

    @MainActor func press(_ object: NSObject) -> Bool {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard object.responds(to: selector) else { return false }
        // SwiftUI accessibility nodes implement the public Objective-C action,
        // but do not declare conformance to the full NSAccessibility protocol.
        typealias PressAction = @convention(c) (AnyObject, Selector) -> Bool
        let action = unsafeBitCast(object.method(for: selector), to: PressAction.self)
        return action(object, selector)
    }

    @MainActor private func writeSnapshot<V: View>(_ root: V, name: String, size: NSSize) async throws {
        let view = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { window.close() }
        window.orderFrontRegardless()
        window.setContentSize(size)
        try await Task.sleep(nanoseconds: 150_000_000)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let bytes = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(bytes.count, 5000, "A native view should render actual content")
        XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)).alphaComponent, 0.9,
                             "The snapshot must contain laid-out content rather than a transparent viewport")
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
                    try await self.writeSnapshot(SettingsView(model: model, navigation: navigation),
                                           name: "settings-\(language)-\(page.rawValue)", size: SettingsWindowLayout.minimumContentSize)
                    if page == .appearance {
                        model.update { $0.style = .overlay }
                        try await self.writeSnapshot(SettingsView(model: model, navigation: navigation),
                            name: "settings-\(language)-appearance-fullscreen", size: SettingsWindowLayout.minimumContentSize)
                        model.update { $0.style = .gentle }
                    }
                }
            }
        }
    }

    func testAboutShowsPackagedVersionBuildAndArchitecture() async throws {
        try await withFixture { model, _, _ in
            model.update { $0.language = "zh-Hans" }
            let navigation = SettingsNavigation()
            navigation.page = .about
            for architecture in ["arm64", "x86_64", "universal"] {
                let buildInfo = AppBuildInfo(infoDictionary: [
                    "CFBundleShortVersionString": "2.4.1",
                    "CFBundleVersion": "108",
                    "AppBuildArchitecture": architecture,
                    "AppBuildConfiguration": "release"
                ])
                let root = SettingsView(model: model, navigation: navigation, buildInfo: buildInfo)
                let view = NSHostingView(rootView: root)
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: SettingsWindowLayout.minimumContentSize),
                                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = view
                defer { window.close() }
                window.orderFront(nil)
                view.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 150_000_000)
                XCTAssertTrue(self.containsText(buildInfo.versionDescription, in: window), architecture)
                try await self.writeSnapshot(root, name: "about-build-\(architecture)", size: SettingsWindowLayout.minimumContentSize)
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
                        try await self.writeSnapshot(root, name: "card-\(language)-\(size.rawValue)-\(running ? "running" : "waiting")",
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

    func testEscapeLeavesRunningAndWaitingRemindersUnchanged() async throws {
        try await withFixture { model, _, _ in
            for style in [ReminderStyle.gentle, .overlay] {
                model.update { $0.style = style; $0.breakStartMode = .manual }
                model.action { $0.startNow(.short, now: Date()) }
                let runningPanel = try XCTUnwrap(self.panels.first)
                model.engine.tick(seconds: 2, now: Date()); model.consume()
                let runningReminder = try XCTUnwrap(model.engine.reminder)
                let beforeRunning = model.saved.records.map(\.id)
                runningPanel.cancelOperation(nil)
                XCTAssertTrue(runningPanel.isVisible)
                XCTAssertTrue(model.engine.isResting)
                XCTAssertEqual(model.engine.reminder?.id, runningReminder.id)
                XCTAssertEqual(model.engine.reminder?.elapsed, runningReminder.elapsed)
                XCTAssertEqual(model.saved.records.map(\.id), beforeRunning)
                try await Task.sleep(nanoseconds: 150_000_000)
                XCTAssertTrue(self.press(try self.button(named: L10n.text("rest.skip"), in: runningPanel)))
                XCTAssertFalse(runningPanel.isVisible)
                XCTAssertFalse(model.engine.isResting)

                model.engine.tick(seconds: 1200, now: Date()); model.engine.tick(seconds: 1, now: Date()); model.consume()
                let waitingPanel = try XCTUnwrap(self.panels.first)
                let waitingReminder = try XCTUnwrap(model.engine.reminder)
                let beforeWaiting = model.saved.records.map(\.id)
                waitingPanel.cancelOperation(nil)
                XCTAssertTrue(waitingPanel.isVisible)
                XCTAssertFalse(model.engine.isResting)
                XCTAssertEqual(model.engine.reminder?.id, waitingReminder.id)
                XCTAssertEqual(model.engine.reminder?.elapsed, waitingReminder.elapsed)
                XCTAssertEqual(model.saved.records.map(\.id), beforeWaiting)
                try await Task.sleep(nanoseconds: 150_000_000)
                XCTAssertTrue(self.press(try self.button(named: L10n.text("rest.skip"), in: waitingPanel)))
                XCTAssertFalse(waitingPanel.isVisible)
            }
        }
    }

    func testPostponeStaysAvailableDuringRestAndShowsWhyItIsDisabled() async throws {
        for style in [ReminderStyle.gentle, .overlay] {
            let sizes: [GentleReminderSize] = style == .gentle ? GentleReminderSize.allCases : [.normal]
            for size in sizes {
                try await withFixture { model, _, _ in
                    model.update { $0.style = style; $0.gentleReminderSize = size; $0.postponeLimit = 2 }
                    model.engine.tick(seconds: 30, now: Date()); model.consume()
                    model.action { $0.startNow(.short, now: Date()) }
                    let reminderID = try XCTUnwrap(model.engine.reminder?.id)
                    let title = L10n.text("rest.defer", 2)
                    for count in 1...2 {
                        model.engine.tick(seconds: 10, now: Date()); model.consume()
                        let panel = try XCTUnwrap(self.panels.first)
                        try await Task.sleep(nanoseconds: 100_000_000)
                        let postpone = try self.button(named: title, in: panel)
                        XCTAssertEqual(self.isEnabled(postpone), true)
                        XCTAssertTrue(self.press(postpone))
                        XCTAssertFalse(panel.isVisible)
                        XCTAssertEqual(model.engine.reminder?.postponements, count)
                        XCTAssertEqual(model.engine.reminder?.id, reminderID)
                        model.engine.tick(seconds: 120, now: Date()); model.consume()
                        XCTAssertTrue(model.engine.isResting)
                        XCTAssertEqual(model.engine.reminder?.elapsed, 0)
                    }
                    model.engine.tick(seconds: 10, now: Date()); model.consume()
                    let panel = try XCTUnwrap(self.panels.first)
                    try await Task.sleep(nanoseconds: 100_000_000)
                    let disabled = try self.button(named: title, in: panel)
                    XCTAssertEqual(self.isEnabled(disabled), false)
                    XCTAssertTrue(self.containsText(L10n.text("rest.defer_limit"), in: panel))
                    let before = model.saved.records.map(\.id)
                    _ = self.press(disabled)
                    XCTAssertTrue(panel.isVisible)
                    XCTAssertTrue(model.engine.isResting)
                    XCTAssertEqual(model.saved.records.map(\.id), before)
                    XCTAssertEqual(TodaySummary(records: model.saved.records, now: Date()).rest, 30)
                    model.action { $0.skip(now: Date()) }

                    model.update { $0.postponeLimit = 0 }
                    model.action { $0.startNow(.short, now: Date()) }
                    let noPostponePanel = try XCTUnwrap(self.panels.first)
                    try await Task.sleep(nanoseconds: 100_000_000)
                    let noPostpone = try self.button(named: title, in: noPostponePanel)
                    XCTAssertEqual(self.isEnabled(noPostpone), false)
                    XCTAssertTrue(self.containsText(L10n.text("rest.defer_disabled"), in: noPostponePanel))
                }
            }
        }
    }

    func testDisabledPostponeMessagesFitMiniCardsAndRenderInAllLanguages() async throws {
        try await withFixture { model, _, _ in
            model.engine.tick(seconds: 30, now: Date()); model.consume()
            model.update { $0.postponeLimit = 1 }
            model.action { $0.startNow(.short, now: Date()) }
            model.action { $0.postpone(now: Date()) }
            model.engine.tick(seconds: 120, now: Date()); model.consume()
            XCTAssertEqual(model.engine.reminder?.postponements, 1)
            for limit in [1, 0] {
                model.update { $0.postponeLimit = limit }
                for language in ["en", "zh-Hans", "zh-Hant", "ja", "ko"] {
                    model.update { $0.language = language }
                    let card = RestCard(model: model, size: .mini, preview: false, previewEnd: {})
                    let width = GentleCardLayout(size: .mini).width
                    let hosting = NSHostingView(rootView: card.frame(width: width))
                    hosting.sizingOptions = [.intrinsicContentSize]
                    let height = ceil(hosting.fittingSize.height)
                    XCTAssertLessThan(height, NSScreen.main!.visibleFrame.height)
                    try await self.writeSnapshot(card, name: "postpone-mini-\(language)-limit\(limit)",
                                           size: NSSize(width: width, height: height))
                    try await self.writeSnapshot(OverlayView(model: model, preview: false, primary: true, previewEnd: {}),
                                           name: "postpone-overlay-\(language)-limit\(limit)",
                                           size: NSSize(width: 1000, height: 700))
                }
            }
        }
    }

    func testRealCardButtonsStartPostponeAndSkip() async throws {
        try await withFixture { model, _, _ in
            model.update { $0.breakStartMode = .manual }
            model.engine.tick(seconds: 1200, now: Date()); model.engine.tick(seconds: 1, now: Date()); model.consume()
            var panel = try XCTUnwrap(self.panels.first)
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertNil(self.findButton(named: L10n.text("common.close"), in: panel))
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
            XCTAssertNil(self.findButton(named: L10n.text("common.close"), in: panel))
            let runningSkip = try self.button(named: L10n.text("rest.skip"), in: panel)
            XCTAssertTrue(self.press(runningSkip))
            XCTAssertFalse(panel.isVisible)
            XCTAssertEqual(model.saved.records.filter { $0.outcome == .skipped }.count, 2)
        }
    }

    func testReminderButtonOrderMatchesInBothStylesAndStates() async throws {
        try await withFixture { model, _, _ in
            for style in ReminderStyle.allCases {
                for size in GentleReminderSize.allCases {
                    model.update { $0.style = style; $0.gentleReminderSize = size; $0.breakStartMode = .manual }
                    model.engine.tick(seconds: 1200, now: Date())
                    if model.engine.reminder == nil { model.engine.tick(seconds: 31, now: Date()) }
                    model.consume()
                    for running in [false, true] {
                        if running { model.action { $0.start(now: Date()) } }
                        try await Task.sleep(nanoseconds: 150_000_000)
                        let panel = try XCTUnwrap(self.panels.first)
                        let reminder = try XCTUnwrap(model.engine.reminder)
                        var titles = [L10n.text(running ? "rest.skip" : "rest.start"),
                                      L10n.text("rest.defer", Int(model.settings.postponement(reminder.kind) / 60))]
                        if !running { titles.append(L10n.text("rest.skip")) }
                        let frames = try titles.map { title -> NSRect in
                            let button = try self.button(named: title, in: panel)
                            let selector = NSSelectorFromString("accessibilityFrame")
                            XCTAssertTrue(button.responds(to: selector))
                            typealias FrameValue = @convention(c) (AnyObject, Selector) -> NSRect
                            return unsafeBitCast(button.method(for: selector), to: FrameValue.self)(button, selector)
                        }
                        for (first, second) in zip(frames, frames.dropFirst()) {
                            XCTAssertFalse(first.isEmpty || second.isEmpty)
                            if abs(first.midY - second.midY) < 1 {
                                XCTAssertLessThan(first.maxX, second.minX)
                            } else {
                                XCTAssertGreaterThan(first.minY, second.maxY)
                            }
                        }
                        XCTAssertNil(self.findButton(named: L10n.text("common.close"), in: panel))
                    }
                    model.action { $0.skip(now: Date()) }
                }
            }
        }
    }

    func testRealSettingsSidebarButtonsNavigateToEveryPage() async throws {
        try await withFixture { model, _, _ in
            let navigation = SettingsNavigation()
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: SettingsWindowLayout.minimumContentSize),
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

    func testFullscreenBackgroundPickerPersistsAndResets() async throws {
        try await withFixture { model, _, _ in
            model.update { $0.style = .overlay; $0.language = "zh-Hans" }
            let navigation = SettingsNavigation(); navigation.page = .appearance
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: SettingsWindowLayout.minimumContentSize),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: model, navigation: navigation))
            defer { window.close() }
            window.orderFrontRegardless()
            try await Task.sleep(nanoseconds: 150_000_000)
            var pending = [try XCTUnwrap(window.contentView)]
            var well: NSColorWell?
            while let view = pending.popLast() {
                if let colorWell = view as? NSColorWell { well = colorWell; break }
                pending += view.subviews
            }
            let picker = try XCTUnwrap(well)
            picker.color = NSColor(srgbRed: 0.8, green: 0.7, blue: 0.6, alpha: 1)
            XCTAssertTrue(picker.sendAction(picker.action, to: picker.target))
            let selected = model.settings.overlayBackgroundColor
            XCTAssertEqual(selected.red, 0.8, accuracy: 0.001)
            XCTAssertEqual(selected.green, 0.7, accuracy: 0.001)
            XCTAssertEqual(selected.blue, 0.6, accuracy: 0.001)
            model.persist()
            XCTAssertEqual(model.store.load().settings.overlayBackgroundColor, selected)
            try await self.writeSnapshot(SettingsView(model: model, navigation: navigation),
                                   name: "settings-zh-Hans-overlay-background", size: SettingsWindowLayout.minimumContentSize)
            XCTAssertTrue(self.press(try self.button(named: L10n.text("background.reset"), in: window)))
            XCTAssertEqual(model.settings.overlayBackgroundColor, Settings.defaultOverlayBackgroundColor)
            XCTAssertEqual(model.store.load().settings.overlayBackgroundColor, Settings.defaultOverlayBackgroundColor)
        }
    }

    func testFullscreenCustomBackgroundRendersInPreviewAndActiveRest() async throws {
        try await withFixture { model, windows, _ in
            model.update { $0.style = .overlay }
            let colors = [Settings.defaultOverlayBackgroundColor,
                          SRGBColor(red: 0.95, green: 0.9, blue: 0.8),
                          SRGBColor(red: 0.1, green: 0.2, blue: 0.6),
                          SRGBColor(red: 1, green: 0, blue: 0),
                          SRGBColor(red: 1, green: 1, blue: 0),
                          SRGBColor(red: 0.46, green: 0.46, blue: 0.46),
                          SRGBColor(red: 0, green: 0, blue: 0),
                          SRGBColor(red: 1, green: 1, blue: 1)]
            for (index, color) in colors.enumerated() {
                model.update { $0.overlayBackgroundColor = color }
                XCTAssertEqual(OverlayPalette(background: color).usesDarkText, [1, 3, 4, 7].contains(index))
                for preview in [true, false] {
                    if preview { windows.preview() }
                    else { model.action { $0.startNow(.short, now: Date()) } }
                    try await Task.sleep(nanoseconds: 150_000_000)
                    for panel in self.panels {
                        let background = try XCTUnwrap(panel.backgroundColor.usingColorSpace(.sRGB))
                        XCTAssertEqual(background.redComponent, color.red, accuracy: 0.001)
                        XCTAssertEqual(background.greenComponent, color.green, accuracy: 0.001)
                        XCTAssertEqual(background.blueComponent, color.blue, accuracy: 0.001)
                        let view = try XCTUnwrap(panel.contentView)
                        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        // Compare a native swatch on the same display, so ColorSync
                        // profiles on different connected screens do not skew RGB values.
                        let swatch = NSView(frame: view.frame)
                        swatch.wantsLayer = true; swatch.layer?.backgroundColor = background.cgColor
                        panel.contentView = swatch
                        defer { panel.contentView = view }
                        let reference = try XCTUnwrap(swatch.bitmapImageRepForCachingDisplay(in: swatch.bounds))
                        swatch.cacheDisplay(in: swatch.bounds, to: reference)
                        let pixel = try XCTUnwrap(bitmap.colorAt(x: 10, y: 10)?.usingColorSpace(.sRGB))
                        let expected = try XCTUnwrap(reference.colorAt(x: 10, y: 10)?.usingColorSpace(.sRGB))
                        XCTAssertEqual(pixel.redComponent, expected.redComponent, accuracy: 0.02)
                        XCTAssertEqual(pixel.greenComponent, expected.greenComponent, accuracy: 0.02)
                        XCTAssertEqual(pixel.blueComponent, expected.blueComponent, accuracy: 0.02)
                    }
                    try await self.writeSnapshot(OverlayView(model: model, preview: preview, primary: true, previewEnd: {}),
                                           name: "overlay-background-\(index)-\(preview ? "preview" : "rest")", size: NSSize(width: 1000, height: 720))
                    if preview { windows.hide() }
                    else { model.action { $0.finish(now: Date()) } }
                }
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
                XCTAssertTrue(self.press(try self.button(named: L10n.text("rest.skip"), in: panel)))
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
                    XCTAssertEqual(self.findButton(named: L10n.text("rest.skip"), in: panel) != nil, panel.frame == screen.frame,
                                   "Only the pointer display may have action buttons")
                    XCTAssertEqual(panel.backingScaleFactor, panel.screen?.backingScaleFactor)
                }
                let primary = try XCTUnwrap(open.first { $0.frame == screen.frame })
                XCTAssertTrue(self.press(try self.button(named: L10n.text("rest.skip"), in: primary)))
                XCTAssertTrue(open.allSatisfy { !$0.isVisible })
                XCTAssertEqual(model.saved.records.filter { $0.outcome == .skipped }.count,
                               NSScreen.screens.first == screen ? 1 : 2)
            }
        }
    }

    func testTwoDisplaysSecondaryEscapeLeavesEveryOverlayOpen() async throws {
        try await withFixture { model, _, _ in
            model.update { $0.style = .overlay; $0.displayScope = .all }
            try await self.onEveryConnectedDisplay { screen in
                model.action { $0.startNow(.long, now: Date()) }
                let open = self.panels
                let secondary = try XCTUnwrap(open.first { $0.frame != screen.frame })
                let before = model.saved.records.map(\.id)
                secondary.cancelOperation(nil)
                XCTAssertTrue(open.allSatisfy(\.isVisible))
                XCTAssertTrue(model.engine.isResting)
                XCTAssertEqual(model.saved.records.map(\.id), before)
                let primary = try XCTUnwrap(open.first { $0.frame == screen.frame })
                try await Task.sleep(nanoseconds: 150_000_000)
                XCTAssertTrue(self.press(try self.button(named: L10n.text("rest.skip"), in: primary)))
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
                    model.action { $0.finish(now: Date()) }
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

    func testPreviewIgnoresEscapeAndCloseAndTimeoutDoNotChangeStatistics() async throws {
        try await withFixture { model, windows, _ in
            let before = model.saved.records.map(\.id)
            for style in [ReminderStyle.gentle, .overlay] {
                model.update { $0.style = style }
                windows.preview()
                let panel = try XCTUnwrap(self.panels.first)
                panel.cancelOperation(nil)
                XCTAssertTrue(panel.isVisible)
                XCTAssertNil(model.engine.reminder)
                XCTAssertEqual(model.saved.records.map(\.id), before)
                try await Task.sleep(nanoseconds: 150_000_000)
                XCTAssertTrue(self.press(try self.button(named: L10n.text("common.close"), in: panel)))
                XCTAssertFalse(panel.isVisible)
            }
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
            model.action { $0.startNow(.short, now: Date()); $0.tick(seconds: 3, now: Date()) }
            let reminder = try XCTUnwrap(model.engine.reminder)
            XCTAssertTrue(model.clearRecords())
            let loaded = model.store.load()
            XCTAssertTrue(loaded.records.isEmpty)
            XCTAssertEqual(loaded.settings, settings)
            XCTAssertEqual(model.store.url.deletingLastPathComponent().path, directory.path)
            XCTAssertEqual(model.engine.reminder?.id, reminder.id)
            XCTAssertEqual(model.engine.reminder?.elapsed, reminder.elapsed)
            model.action { $0.tick(seconds: 1, now: Date()) }
            XCTAssertEqual(model.engine.reminder?.elapsed, reminder.elapsed + 1)
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
