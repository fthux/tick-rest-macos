import AppKit
import SwiftUI
import XCTest
import TickRestCore
@testable import TickRestApp

extension AppIntegrationTests {
    func testGentlePositionsRespectOffsetDisplaysAndSmallScreenMargins() {
        let screen = NSRect(x: -1200, y: 100, width: 1000, height: 700)
        let size = NSSize(width: 400, height: 200)
        let origins: [NSPoint] = [
            NSPoint(x: -1168, y: 570), NSPoint(x: -900, y: 570), NSPoint(x: -632, y: 570),
            NSPoint(x: -1168, y: 350), NSPoint(x: -900, y: 350), NSPoint(x: -632, y: 350),
            NSPoint(x: -1168, y: 130), NSPoint(x: -900, y: 130), NSPoint(x: -632, y: 130)
        ]
        for (position, origin) in zip(GentleReminderPosition.allCases, origins) {
            let frame = GentleReminderPlacement.frame(size: size, in: screen, position: position)
            XCTAssertEqual(frame.origin, origin, position.rawValue)
            XCTAssertTrue(screen.contains(frame))
            let smallScreen = NSRect(x: 500, y: -700, width: 420, height: 220)
            XCTAssertTrue(smallScreen.contains(GentleReminderPlacement.frame(size: size, in: smallScreen, position: position)))
        }
    }

    func testGentlePositionGridControlsPersistAndMovePreview() async throws {
        try await withFixture { model, windows, _ in
            let navigation = SettingsNavigation(); navigation.page = .appearance
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: model, navigation: navigation))
            defer { window.close() }
            window.orderFrontRegardless()
            windows.preview()
            let panel = try XCTUnwrap(self.panels.first)
            for language in ["en", "zh-Hans"] {
                model.update { $0.language = language }
                for position in GentleReminderPosition.allCases {
                    try await Task.sleep(nanoseconds: 50_000_000)
                    XCTAssertTrue(self.press(try self.button(named: position.title, in: window)))
                    windows.refresh()
                    XCTAssertEqual(model.settings.gentleReminderPosition, position)
                    XCTAssertEqual(model.store.load().settings.gentleReminderPosition, position)
                    let screen = try XCTUnwrap(panel.screen)
                    XCTAssertEqual(panel.frame, GentleReminderPlacement.frame(size: panel.frame.size,
                        in: screen.visibleFrame, position: position))
                    XCTAssertTrue(panel.isVisible)
                    XCTAssertNil(model.engine.reminder)
                    XCTAssertTrue(model.saved.records.isEmpty)
                }
            }
        }
    }

    func testGentlePositionsApplyToEverySizeAndStayAnchoredWhenContentResizes() async throws {
        try await withFixture { model, windows, _ in
            for size in GentleReminderSize.allCases {
                for position in GentleReminderPosition.allCases {
                    model.update { $0.gentleReminderSize = size; $0.gentleReminderPosition = position }
                    windows.preview()
                    let panel = try XCTUnwrap(self.panels.first)
                    let screen = try XCTUnwrap(panel.screen)
                    XCTAssertEqual(panel.frame, GentleReminderPlacement.frame(size: panel.frame.size,
                        in: screen.visibleFrame, position: position))
                    XCTAssertTrue(screen.visibleFrame.contains(panel.frame))
                    windows.hide()
                }
            }
            model.update { $0.breakStartMode = .manual; $0.gentleReminderSize = .mini }
            model.engine.tick(seconds: 1200, now: Date())
            model.engine.tick(seconds: 30, now: Date()); model.consume()
            let panel = try XCTUnwrap(self.panels.first)
            let screen = try XCTUnwrap(panel.screen)
            let id = model.engine.reminder?.id
            for position in [GentleReminderPosition.topCenter, .center, .bottomCenter] {
                model.update { $0.gentleReminderPosition = position; $0.language = "ko"; $0.postponeLimit = 0 }
                try await Task.sleep(nanoseconds: 50_000_000)
                windows.refresh()
                XCTAssertEqual(panel.frame, GentleReminderPlacement.frame(size: panel.frame.size,
                    in: screen.visibleFrame, position: position))
                XCTAssertEqual(panel.frame.height, ceil(try XCTUnwrap(panel.contentView).fittingSize.height))
                XCTAssertEqual(model.engine.reminder?.id, id)
                XCTAssertTrue(panel.isVisible)
            }
            model.action { $0.start(now: Date()) }
            try await Task.sleep(nanoseconds: 50_000_000)
            windows.refresh()
            XCTAssertEqual(panel.frame.minY, screen.visibleFrame.minY + 30, accuracy: 1)
            XCTAssertEqual(panel.frame.midX, screen.visibleFrame.midX, accuracy: 1)
            XCTAssertEqual(model.engine.reminder?.id, id)
        }
    }
}
