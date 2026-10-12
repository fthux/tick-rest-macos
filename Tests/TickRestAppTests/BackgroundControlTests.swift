import Foundation
import SwiftUI
import XCTest
import TickRestCore
@testable import TickRestApp

/// Bindings and event delivery only: no application, native controls or windows.
final class BackgroundControlTests: XCTestCase {
    func testGradientRailKeepsUpdatingTheSameStopAcrossOtherStops() throws {
        var gradient = BackgroundGradient(colors: [.hex("112233")!, .hex("445566")!, .hex("778899")!])
        gradient.stops[0].location = 0.2
        gradient.stops[1].location = 0.5
        gradient.stops[2].location = 0.8
        let original = gradient.stops
        let moving = original[1].id
        var drag = GradientRailDrag()
        // Select the middle stop while the editor previously selected the first.
        XCTAssertEqual(drag.update(gradient: &gradient, x: 110, width: 220, preferredID: original[0].id), moving)
        for location in [0.65, 0.9, 0.95, 0.7, 0.15, 0.05, 0.4] {
            XCTAssertEqual(drag.update(gradient: &gradient, x: 10 + location * 200, width: 220,
                                      preferredID: original[2].id), moving)
            let stop = try XCTUnwrap(gradient.stops.first { $0.id == moving })
            XCTAssertEqual(stop.location, location, accuracy: 0.0001)
            XCTAssertEqual(stop.color, original[1].color)
            for unchanged in [original[0], original[2]] {
                XCTAssertEqual(gradient.stops.first { $0.id == unchanged.id }, unchanged)
            }
        }
    }

    func testGradientRailClampsEndpointsAndNewGesturesCanSelectAnotherStop() throws {
        var gradient = BackgroundGradient()
        let first = gradient.stops[0].id, last = gradient.stops[1].id
        var drag = GradientRailDrag()
        XCTAssertEqual(drag.update(gradient: &gradient, x: 10, width: 220, preferredID: last), first)
        _ = drag.update(gradient: &gradient, x: -30, width: 220, preferredID: last)
        XCTAssertEqual(gradient.stops.first { $0.id == first }?.location, 0)
        _ = drag.update(gradient: &gradient, x: 260, width: 220, preferredID: last)
        XCTAssertEqual(gradient.stops.first { $0.id == first }?.location, 1)
        drag = GradientRailDrag()
        // Overlapping stops prefer the currently selected marker.
        XCTAssertEqual(drag.update(gradient: &gradient, x: 210, width: 220, preferredID: last), last)
        _ = drag.update(gradient: &gradient, x: 90, width: 220, preferredID: first)
        XCTAssertEqual(gradient.stops.first { $0.id == last }?.location, 0.4)
        let before = gradient
        XCTAssertNil(drag.update(gradient: &gradient, x: .nan, width: 220, preferredID: first))
        XCTAssertNil(drag.update(gradient: &gradient, x: 0, width: 20, preferredID: first))
        XCTAssertEqual(gradient, before)
    }

    func testSliderUpdatesEachSampleBeforeTheGestureEnds() throws {
        var background = OverlayBackground()
        background.kind = .wallpaper; background.wallpaper.source = .system
        var received: [Double] = []
        let writer = DebouncedStateWriter(delay: 10) { _ in }
        let value = Binding<Double>(get: { background.activeProtection * 100 }, set: {
            background.activeProtection = $0 / 100
            background = background.normalized
            received.append(background.activeProtection)
            var data = SavedData(); data.settings.overlayBackground = background
            writer.schedule(data) { _ in XCTFail("Unexpected persistence failure") }
        })
        let coordinator = ContinuousBackgroundSlider.Coordinator(value: value, range: 60...90, step: 1)
        coordinator.receive(60)
        XCTAssertEqual(background.activeProtection, 0.6)
        coordinator.receive(75)
        XCTAssertEqual(background.activeProtection, 0.75)
        coordinator.receive(90)
        XCTAssertEqual(background.activeProtection, 0.9)
        coordinator.receive(65, enabled: false)
        XCTAssertEqual(received, [0.6, 0.75, 0.9])
        XCTAssertEqual(background.wallpaperProtection.desktop, 0.65)
        XCTAssertEqual(background.wallpaperProtection.custom, 0.65)
        XCTAssertEqual(background.protection, 0.65)
        // These are the actual backing opacities used by both previews. Over
        // white their remaining brightness changes from 40% to 10%.
        XCTAssertEqual(1 - received.first!, 0.4, accuracy: 0.0001)
        XCTAssertEqual(1 - received.last!, 0.1, accuracy: 0.0001)
        try writer.flush(SavedData())
    }
    func testContinuousSliderClampsAndQuantizesWithoutLosingEndpoints() {
        XCTAssertEqual(SliderValue.quantized(73.6, range: 60...90, step: 1), 74)
        XCTAssertEqual(SliderValue.quantized(-20, range: 60...90, step: 1), 60)
        XCTAssertEqual(SliderValue.quantized(120, range: 60...90, step: 1), 90)
        XCTAssertEqual(SliderValue.quantized(.nan, range: 60...90, step: 1), 60)
        XCTAssertEqual(SliderValue.quantized(0.33, range: 0...1, step: 0.1), 0.3, accuracy: 0.0001)
    }
}
