import AppKit
import SwiftUI
import XCTest
import TickRestCore
@testable import TickRestApp

extension AppIntegrationTests {
    /// Exercise a naturally expiring pause while the existing native menu is open.
    func testOpenMenuReplacesResumeActionWhenTimedPauseExpires() async throws {
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
            defer {
                NotificationCenter.default.removeObserver(delegate)
                DistributedNotificationCenter.default().removeObserver(delegate)
                delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
                NSStatusBar.system.removeStatusItem(status)
            }
            let pauseEnd = Date().addingTimeInterval(10)
            model.action { $0.setPause(.until(pauseEnd), now: Date()) }
            let menu = try XCTUnwrap(status.menu)
            delegate.menuWillOpen(menu)
            XCTAssertNotNil(menu.item(withTitle: L10n.text("menu.resume")))
            model.action { $0.tick(seconds: 0, now: pauseEnd) }
            try await Task.sleep(nanoseconds: 150_000_000)
            XCTAssertNil(model.engine.pause)
            XCTAssertNil(menu.item(withTitle: L10n.text("menu.resume")), "Expired pause must remove the stale Resume action")
            XCTAssertNotNil(menu.item(withTitle: L10n.text("menu.pause")), "The now-working menu must expose Pause")
            model.action { $0.setPause(.indefinite, now: Date()) }
            try await Task.sleep(nanoseconds: 150_000_000)
            XCTAssertNotNil(menu.item(withTitle: L10n.text("menu.resume")))
            XCTAssertNil(menu.item(withTitle: L10n.text("menu.pause")))
            delegate.menuDidClose(menu)
        }
    }

}
