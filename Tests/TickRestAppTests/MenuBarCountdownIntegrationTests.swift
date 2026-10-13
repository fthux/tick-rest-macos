import AppKit
import XCTest
import TickRestCore
@testable import TickRestApp

extension AppIntegrationTests {
    func testMenuCountdownRefreshesBetweenEngineTicksInTrackingModeAndStopsOnTermination() async throws {
        try await withFixture { _, _, directory in
            let store = DataStore(url: directory.appendingPathComponent("delegate/state.json"))
            var saved = SavedData(); saved.settings.language = "en"
            saved.settings.onboardingComplete = true; saved.settings.detectIdle = false
            saved.settings.avoidFullscreen = false; saved.settings.prewarning = 0
            try store.save(saved)
            let delegate = AppDelegate(store: store, lockDirectory: directory.appendingPathComponent("lock"))
            delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
            func field<T>(_ name: String, in object: Any, _ type: T.Type) throws -> T {
                try XCTUnwrap(Mirror(reflecting: object).children.first { $0.label == name }?.value as? T)
            }
            func trackMenu(for duration: TimeInterval) {
                let deadline = Date().addingTimeInterval(duration)
                while Date() < deadline { RunLoop.main.run(mode: .eventTracking, before: deadline) }
            }
            let model = try field("model", in: delegate, AppController.self)
            let status = try field("status", in: delegate, NSStatusItem.self)
            let timer = try field("countdownTimer", in: delegate, Timer.self)
            var terminated = false
            defer {
                NotificationCenter.default.removeObserver(delegate)
                DistributedNotificationCenter.default().removeObserver(delegate)
                if !terminated { delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }
                NSStatusBar.system.removeStatusItem(status)
            }
            // Isolate the real display timer: it must not need an engine tick to refresh.
            try field("timer", in: model, Timer.self).invalidate()
            model.engine.tick(seconds: model.engine.remaining(.short) - 1.4, now: Date())
            model.consume(countdownUptime: ProcessInfo.processInfo.systemUptime)
            model.revision += 1
            try await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertTrue(status.button!.attributedTitle.string.contains("00:02"))
            let elapsed = model.engine.shortElapsed, records = model.saved.records
            trackMenu(for: 0.6)
            XCTAssertTrue(status.button!.attributedTitle.string.contains("00:01"))
            XCTAssertEqual(model.engine.shortElapsed, elapsed)
            XCTAssertEqual(model.saved.records.map(\.id), records.map(\.id))
            XCTAssertEqual(model.saved.records.map(\.seconds), records.map(\.seconds))
            XCTAssertEqual(model.saved.records.map(\.date), records.map(\.date))
            model.action { $0.setPause(.indefinite, now: Date()) }
            try await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertTrue(status.button!.attributedTitle.string.contains(L10n.text("menu.paused_short")))
            model.update { $0.showCountdown = false; $0.showStatusDot = false }
            try await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertEqual(status.button!.attributedTitle.string, "")
            model.update { $0.showCountdown = true }
            model.action { $0.startNow(.short, now: Date()) }
            try await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertTrue(status.button!.attributedTitle.string.contains(L10n.clock(model.engine.reminder!.target)))
            delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            terminated = true
            XCTAssertFalse(timer.isValid)
        }
    }

    func testPeriodicSaveCannotOverwriteLaterRecordClear() async throws {
        try await withFixture { model, _, _ in
            model.engine.tick(seconds: 5, now: Date()); model.consume()
            XCTAssertFalse(model.saved.records.isEmpty)
            model.persist(deferPersistence: true)
            XCTAssertTrue(model.clearRecords())
            try await Task.sleep(nanoseconds: 500_000_000)
            XCTAssertTrue(model.store.load().records.isEmpty)
        }
    }
}
