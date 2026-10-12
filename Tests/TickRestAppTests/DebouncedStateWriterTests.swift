import Foundation
import XCTest
import TickRestCore
@testable import TickRestApp

final class DebouncedStateWriterTests: XCTestCase {
    func testBurstWritesOnlyLatestStateOffTheMainThread() {
        let completed = expectation(description: "Debounced save")
        completed.expectedFulfillmentCount = 1
        completed.assertForOverFulfill = true
        let writer = DebouncedStateWriter(delay: 0.05) { data in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertEqual(data.settings.overlayBackground.gradient.angle, 99)
            completed.fulfill()
        }
        for value in 0..<100 {
            var data = SavedData(); data.settings.overlayBackground.gradient.angle = Double(value)
            writer.schedule(data) { _ in XCTFail("Unexpected save error") }
        }
        wait(for: [completed], timeout: 2)
        withExtendedLifetime(writer) {}
    }

    func testFlushSupersedesPendingEditsAndLaterSaveKeepsNewerState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DataStore(url: directory.appendingPathComponent("state.json"))
        let writer = DebouncedStateWriter(delay: 10) { try store.save($0) }
        var old = SavedData(); old.settings.overlayBackground.gradient.angle = 90
        writer.schedule(old) { _ in XCTFail("Unexpected save error") }
        var cleared = SavedData(); cleared.settings.overlayBackground.gradient.angle = 180
        try writer.flush(cleared)
        XCTAssertEqual(store.load().settings.overlayBackground.gradient.angle, 180)
        var latest = SavedData(); latest.settings.overlayBackground.gradient.angle = 270
        writer.schedule(latest) { _ in XCTFail("Unexpected save error") }
        try writer.flush(latest)
        XCTAssertEqual(store.load().settings.overlayBackground.gradient.angle, 270)
    }

    func testFlushWaitsForInflightSaveBeforeCommittingNewerState() throws {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var values: [Double] = []
        let writer = DebouncedStateWriter(delay: 0) { data in
            if data.settings.overlayBackground.gradient.angle == 90 {
                entered.signal(); release.wait()
            }
            lock.lock(); values.append(data.settings.overlayBackground.gradient.angle); lock.unlock()
        }
        var old = SavedData(); old.settings.overlayBackground.gradient.angle = 90
        writer.schedule(old) { _ in XCTFail("Unexpected save error") }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        let finished = expectation(description: "Ordered flush")
        var latest = SavedData(); latest.settings.overlayBackground.gradient.angle = 180
        DispatchQueue.global().async {
            do { try writer.flush(latest) } catch { XCTFail("Flush failed: \(error)") }
            finished.fulfill()
        }
        release.signal(); wait(for: [finished], timeout: 2)
        lock.lock(); let result = values; lock.unlock()
        XCTAssertEqual(result, [90, 180])
    }

    func testDeferredErrorsReturnToTheMainThreadAndFlushReportsErrors() {
        let failed = expectation(description: "Save error")
        let writer = DebouncedStateWriter(delay: 0) { _ in throw CocoaError(.fileWriteNoPermission) }
        writer.schedule(SavedData()) { _ in
            XCTAssertTrue(Thread.isMainThread); failed.fulfill()
        }
        wait(for: [failed], timeout: 2)
        XCTAssertThrowsError(try writer.flush(SavedData()))
    }
}
