import Foundation
import XCTest
@testable import TickRestApp

/// Uses synthetic displays and injected callbacks; never constructs native UI.
final class DisplayIdentificationTests: XCTestCase {
    private final class Harness {
        let targets = [
            "left": DisplayIdentificationTarget(display: ConnectedDisplay(id: "left", name: "DELL U2723QE"),
                frame: CGRect(x: -1920, y: 200, width: 1920, height: 1080)),
            "right": DisplayIdentificationTarget(display: ConnectedDisplay(id: "right", name: "DELL U2723QE"),
                frame: CGRect(x: 1400, y: -300, width: 1920, height: 1080))
        ]
        var shown: [DisplayIdentificationTarget] = []
        var closed: [String] = []
        var timeouts: [() -> Void] = []
        var delays: [TimeInterval] = []
        var canceled: [Int] = []

        func controller() -> DisplayIdentificationController {
            DisplayIdentificationController(resolve: { self.targets[$0] }, present: { target in
                self.shown.append(target)
                return { self.closed.append(target.display.id) }
            }, schedule: { delay, action in
                let index = self.timeouts.count
                self.delays.append(delay); self.timeouts.append(action)
                return { self.canceled.append(index) }
            })
        }
    }

    func testSameNameDisplaysAreIdentifiedByIDAtTheirOwnOffsetFrames() throws {
        let harness = Harness(); let controller = harness.controller()
        for id in ["left", "right"] {
            controller.identify(id)
            let shown = try XCTUnwrap(harness.shown.last)
            XCTAssertEqual(shown.display.id, id)
            XCTAssertEqual(shown.display.name, "DELL U2723QE")
            XCTAssertEqual(shown.frame, harness.targets[id]?.frame)
        }
    }

    func testHintExpiresAfterThreeSecondsAndClosesOnlyOnce() {
        let harness = Harness(); let controller = harness.controller()
        controller.identify("left")
        XCTAssertEqual(harness.delays, [3])
        XCTAssertTrue(harness.closed.isEmpty)
        harness.timeouts[0]()
        harness.timeouts[0]()
        XCTAssertEqual(harness.closed, ["left"])
        XCTAssertEqual(harness.canceled, [0])
    }

    func testOldCanceledTimeoutCannotCloseTheReplacementHint() {
        let harness = Harness(); let controller = harness.controller()
        controller.identify("left")
        controller.identify("right")
        XCTAssertEqual(harness.closed, ["left"])
        XCTAssertEqual(harness.canceled, [0])
        harness.timeouts[0]()
        XCTAssertEqual(harness.closed, ["left"])
        harness.timeouts[1]()
        XCTAssertEqual(harness.closed, ["left", "right"])
    }

    func testRepeatedIdentificationRestartsDurationWithoutStackingHints() {
        let harness = Harness(); let controller = harness.controller()
        controller.identify("left"); controller.identify("left")
        XCTAssertEqual(harness.closed, ["left"])
        XCTAssertEqual(harness.delays, [3, 3])
        harness.timeouts[0]()
        XCTAssertEqual(harness.closed, ["left"])
        harness.timeouts[1]()
        XCTAssertEqual(harness.closed, ["left", "left"])
    }

    func testMissingOrDisconnectedTargetDoesNotIdentifyAnotherScreen() {
        let harness = Harness(); let controller = harness.controller()
        controller.identify(nil); controller.identify("disconnected")
        XCTAssertTrue(harness.shown.isEmpty)
        XCTAssertTrue(harness.timeouts.isEmpty)
        controller.identify("left"); controller.identify("disconnected")
        XCTAssertEqual(harness.shown.count, 1)
        XCTAssertEqual(harness.closed, ["left"])
        XCTAssertEqual(harness.canceled, [0])
    }

    func testScreenChangesOrLeavingSettingsCanClearTheHintIdempotently() {
        let harness = Harness(); let controller = harness.controller()
        controller.identify("right")
        controller.clear(); controller.clear()
        harness.timeouts[0]()
        XCTAssertEqual(harness.closed, ["right"])
        XCTAssertEqual(harness.canceled, [0])
    }

    func testControllerReleaseCancelsTimeoutAndClosesHint() {
        let harness = Harness()
        var controller: DisplayIdentificationController? = harness.controller()
        weak var reference = controller
        controller?.identify("left")
        controller = nil
        XCTAssertNil(reference)
        XCTAssertEqual(harness.closed, ["left"])
        XCTAssertEqual(harness.canceled, [0])
        harness.timeouts[0]()
        XCTAssertEqual(harness.closed, ["left"])
    }
}
