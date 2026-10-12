import Foundation
import XCTest
@testable import TickRestApp

/// Standalone Foundation centers only; no workspace events or application UI.
final class NotificationObservationsTests: XCTestCase {
    func testDeinitRemovesRegistrationsFromEveryOwningCenter() {
        let first = NotificationCenter(), second = NotificationCenter()
        let name = Notification.Name("HeadlessObservationTest")
        var observations: NotificationObservations? = NotificationObservations()
        var firstCount = 0, secondCount = 0, unrelatedCount = 0
        observations?.observe(first, name: name, queue: nil) { _ in firstCount += 1 }
        observations?.observe(second, name: name, queue: nil) { _ in secondCount += 1 }
        let unrelated = first.addObserver(forName: name, object: nil, queue: nil) { _ in unrelatedCount += 1 }
        defer { first.removeObserver(unrelated) }
        first.post(name: name, object: nil); second.post(name: name, object: nil)
        XCTAssertEqual(firstCount, 1); XCTAssertEqual(secondCount, 1)
        weak var released = observations
        observations = nil
        XCTAssertNil(released)
        first.post(name: name, object: nil); second.post(name: name, object: nil)
        XCTAssertEqual(firstCount, 1); XCTAssertEqual(secondCount, 1)
        XCTAssertEqual(unrelatedCount, 2)
    }
}
