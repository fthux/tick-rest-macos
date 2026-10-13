import AppKit
import SwiftUI
import XCTest
import TickRestCore
@testable import TickRestApp

extension AppIntegrationTests {
    func testSettingsMinimumAfterToolbarSettlesAndAppearanceControlsRender() async throws {
        try await withFixture { _, _, directory in
            let store = DataStore(url: directory.appendingPathComponent("delegate/state.json"))
            var saved = SavedData(); saved.settings.language = "en"
            saved.settings.onboardingComplete = true; saved.settings.avoidFullscreen = false
            try store.save(saved)
            let delegate = AppDelegate(store: store, lockDirectory: directory.appendingPathComponent("lock"))
            delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
            func field<T>(_ name: String, _ type: T.Type) throws -> T {
                try XCTUnwrap(Mirror(reflecting: delegate).children.first { $0.label == name }?.value as? T)
            }
            let model = try field("model", AppController.self)
            let status = try field("status", NSStatusItem.self)
            delegate.openSettings()
            let window = try field("settingsWindow", NSWindow.self)
            defer {
                window.close()
                NotificationCenter.default.removeObserver(delegate)
                DistributedNotificationCenter.default().removeObserver(delegate)
                delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
                NSStatusBar.system.removeStatusItem(status)
            }
            print("AUDIT initial minimum: frame=\(window.frame), min=\(window.minSize), contentMin=\(window.contentMinSize)")
            for _ in 0..<20 {
                if window.toolbar != nil && window.minSize.height >= SettingsWindowLayout.minimumFrameSize.height { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            print("AUDIT settled minimum: frame=\(window.frame), min=\(window.minSize), contentMin=\(window.contentMinSize)")
            XCTAssertGreaterThanOrEqual(window.minSize.height, SettingsWindowLayout.minimumFrameSize.height)
            let navigation = try field("settingsNavigation", SettingsNavigation.self)
            navigation.page = .appearance
            window.setFrame(NSRect(origin: window.frame.origin, size: window.minSize), display: true)
            let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent(".build/full-audit-20261014")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            for language in ["en", "zh-Hans", "zh-Hant", "ja", "ko"] {
                model.update { $0.language = language }
                try await Task.sleep(nanoseconds: 300_000_000)
                let view = try XCTUnwrap(window.contentView)
                view.layoutSubtreeIfNeeded()
                XCTAssertNotNil(self.findButton(named: L10n.text("reminder.test_sound"), in: view))
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let bytes = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try bytes.write(to: output.appendingPathComponent("actual-minimum-\(language).png"))
                print("AUDIT \(language) actual minimum: frame=\(window.frame), content=\(view.bounds)")
            }
        }
    }}
