import AppKit
import SwiftUI
import XCTest
import TickRestCore
@testable import TickRestApp

extension AppIntegrationTests {
    func testPrivacyResetEntryMatchesBuildConfigurationAndCancelPreservesData() async throws {
        try await withFixture { model, _, _ in
            let navigation = SettingsNavigation(); navigation.page = .privacy
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 1000),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: model, navigation: navigation))
            window.makeKeyAndOrderFront(nil); defer { window.close() }
            try await Task.sleep(nanoseconds: 250_000_000)
#if DEBUG
            let before = try Data(contentsOf: model.store.url)
            XCTAssertTrue(self.press(try self.button(named: L10n.text("debug.reset_action"), in: window)))
            try await Task.sleep(nanoseconds: 200_000_000)
            let confirmation = try XCTUnwrap(window.attachedSheet)
            _ = self.press(try self.button(named: L10n.text("common.cancel"), in: confirmation))
            try await Task.sleep(nanoseconds: 200_000_000)
            XCTAssertNil(window.attachedSheet)
            XCTAssertEqual(try Data(contentsOf: model.store.url), before)
            XCTAssertFalse(model.debugDataCleared)
#else
            XCTAssertNil(self.findButton(named: L10n.text("debug.reset_action"), in: window))
#endif
        }
    }

#if DEBUG
    func testDebugResetErasesAllLocalDataPreservesLockAndCannotBeUndoneByShutdownSaves() async throws {
        try await withFixture { model, _, directory in
            let files = FileManager.default
            model.action { $0.startNow(.short, now: Date()); $0.skip(now: Date()) }
            model.update(deferPersistence: true) { $0.theme = .dark }
            let lockURL = directory.appendingPathComponent("instance.lock")
            try Data("lock".utf8).write(to: lockURL)
            let lockInode = try files.attributesOfItem(atPath: lockURL.path)[.systemFileNumber] as? NSNumber
            let wallpapers = directory.appendingPathComponent("Wallpapers")
            try files.createDirectory(at: wallpapers, withIntermediateDirectories: true)
            try Data("wallpaper".utf8).write(to: wallpapers.appendingPathComponent("import.png"))
            try Data("backup".utf8).write(to: directory.appendingPathComponent("state-v1-backup.json"))
            let outside = directory.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
            try Data("keep".utf8).write(to: outside)
            defer { try? files.removeItem(at: outside) }

            XCTAssertTrue(model.clearAllDataForDebug())
            XCTAssertTrue(model.debugDataCleared)
            XCTAssertEqual(try files.contentsOfDirectory(atPath: directory.path), ["instance.lock"])
            XCTAssertEqual(try files.attributesOfItem(atPath: lockURL.path)[.systemFileNumber] as? NSNumber, lockInode)
            XCTAssertEqual(try Data(contentsOf: outside), Data("keep".utf8))
            // Simulate the normal shutdown and deferred-edit paths after reset.
            model.consume(); model.persist()
            model.update(deferPersistence: true) { $0.theme = .light }
            try await Task.sleep(nanoseconds: 500_000_000)
            XCTAssertFalse(files.fileExists(atPath: model.store.url.path))
            let fresh = AppController(store: DataStore(url: model.store.url))
            XCTAssertEqual(fresh.settings, Settings())
            XCTAssertFalse(fresh.settings.onboardingComplete)
            XCTAssertTrue(fresh.saved.records.isEmpty)
            XCTAssertEqual(fresh.engine.shortElapsed, 0)
            XCTAssertEqual(fresh.engine.longElapsed, 0)
        }
    }

    func testDebugResetFailureDoesNotReportSuccess() async throws {
        try await withFixture { _, _, directory in
            let blocked = directory.appendingPathComponent("not-a-directory")
            try Data("keep".utf8).write(to: blocked)
            let model = AppController(store: DataStore(url: blocked.appendingPathComponent("state.json")))
            XCTAssertFalse(model.clearAllDataForDebug())
            XCTAssertFalse(model.debugDataCleared)
            XCTAssertNotNil(model.errorMessage)
            XCTAssertEqual(try Data(contentsOf: blocked), Data("keep".utf8))
        }
    }
#endif
}

#if DEBUG
final class DebugResetWriterTests: XCTestCase {
    func testResetWaitsForInflightWriteAndRejectsPendingAndFutureSaves() throws {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var events: [String] = []
        let writer = DebouncedStateWriter(delay: 0) { _ in
            entered.signal(); release.wait()
            lock.lock(); events.append("save"); lock.unlock()
        }
        writer.schedule(SavedData()) { _ in XCTFail("Unexpected save error") }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        let finished = expectation(description: "Reset after write")
        DispatchQueue.global().async {
            do {
                try writer.resetForDebug {
                    lock.lock(); events.append("erase"); lock.unlock()
                }
            } catch { XCTFail("Reset failed: \(error)") }
            finished.fulfill()
        }
        release.signal()
        wait(for: [finished], timeout: 2)
        writer.schedule(SavedData()) { _ in XCTFail("Unexpected save error") }
        try writer.flush(SavedData())
        lock.lock(); let result = events; lock.unlock()
        XCTAssertEqual(result, ["save", "erase"])
    }
}
#endif
