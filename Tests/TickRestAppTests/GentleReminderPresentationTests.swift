import AppKit
import XCTest
import TickRestCore
@testable import TickRestApp

/// Pure display-state/geometry tests: no NSApplication, windows or user store.
final class GentleReminderPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func settings(manual: Bool = false) -> Settings {
        var settings = Settings()
        settings.style = .gentle
        settings.prewarning = 0
        settings.breakStartMode = manual ? .manual : .automatic
        return settings
    }

    private func consume(_ engine: Engine, into presentation: inout GentleReminderPresentation) -> [Record] {
        let (effects, records) = engine.drain()
        for effect in effects { presentation.apply(effect, settings: engine.settings) }
        return records
    }

    func testCollapseChangesBothDimensionsAndExpansionRestoresEveryConfiguredSize() {
        for size in GentleReminderSize.allCases {
            var presentation = GentleReminderPresentation()
            presentation.begin(size: size)
            let width = GentleCardLayout(size: size).width
            XCTAssertEqual(presentation.width, width)
            for _ in 0..<5 {
                presentation.setCollapsed(true)
                XCTAssertEqual(presentation.width, 240)
                XCTAssertEqual(presentation.expandedSize, size)
                presentation.setCollapsed(false)
                XCTAssertEqual(presentation.width, width)
            }
        }
        XCTAssertEqual(GentleReminderPresentation.collapsedHeight, 56)
    }

    func testCollapseNeverChangesEngineSnapshotRecordsOrEffects() throws {
        let engine = Engine(settings: settings(), now: now)
        var presentation = GentleReminderPresentation()
        engine.tick(seconds: 1200, now: now)
        _ = consume(engine, into: &presentation)
        engine.tick(seconds: 3, now: now.addingTimeInterval(3))
        _ = consume(engine, into: &presentation)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let before = try encoder.encode(engine.snapshot(now: now))
        for _ in 0..<5 {
            presentation.setCollapsed(true)
            presentation.setCollapsed(false)
        }
        XCTAssertEqual(try encoder.encode(engine.snapshot(now: now)), before)
        XCTAssertTrue(engine.records.isEmpty)
        XCTAssertTrue(engine.effects.isEmpty)
    }

    func testAutomaticCountdownContinuesWhileCollapsedAndCompletionClearsPresentation() throws {
        let engine = Engine(settings: settings(), now: now)
        var presentation = GentleReminderPresentation()
        engine.tick(seconds: 1200, now: now)
        _ = consume(engine, into: &presentation)
        let id = try XCTUnwrap(engine.reminder?.id)
        presentation.setCollapsed(true)
        engine.tick(seconds: 3, now: now.addingTimeInterval(3))
        _ = consume(engine, into: &presentation)
        XCTAssertTrue(presentation.isCollapsed)
        XCTAssertTrue(engine.isResting)
        XCTAssertEqual(engine.reminder?.id, id)
        XCTAssertEqual(engine.reminder?.elapsed, 3)
        engine.tick(seconds: 17, now: now.addingTimeInterval(20))
        let records = consume(engine, into: &presentation)
        XCTAssertEqual(records.filter { $0.outcome == .completed }.count, 1)
        XCTAssertNil(presentation.expandedSize)
        XCTAssertFalse(presentation.isCollapsed)
        XCTAssertNil(engine.reminder)
    }

    func testManualWaitingAndStartPreserveCollapsedStateWithoutPrematureCounting() {
        let engine = Engine(settings: settings(manual: true), now: now)
        var presentation = GentleReminderPresentation()
        engine.tick(seconds: 1200, now: now)
        _ = consume(engine, into: &presentation)
        presentation.setCollapsed(true)
        engine.tick(seconds: 5, now: now.addingTimeInterval(5))
        _ = consume(engine, into: &presentation)
        XCTAssertFalse(engine.isResting)
        XCTAssertEqual(engine.reminder?.elapsed, 0)
        XCTAssertTrue(presentation.isCollapsed)
        engine.start(now: now.addingTimeInterval(5))
        _ = consume(engine, into: &presentation)
        engine.tick(seconds: 1, now: now.addingTimeInterval(6))
        _ = consume(engine, into: &presentation)
        XCTAssertTrue(engine.isResting)
        XCTAssertEqual(engine.reminder?.elapsed, 1)
        XCTAssertTrue(presentation.isCollapsed)
    }

    func testPostponementReusesReminderIDButNextPresentationIsExpanded() throws {
        let engine = Engine(settings: settings(manual: true), now: now)
        var presentation = GentleReminderPresentation()
        engine.tick(seconds: 1200, now: now)
        _ = consume(engine, into: &presentation)
        let id = try XCTUnwrap(engine.reminder?.id)
        presentation.setCollapsed(true)
        engine.postpone(now: now)
        _ = consume(engine, into: &presentation)
        XCTAssertNil(presentation.expandedSize)
        engine.tick(seconds: 120, now: now.addingTimeInterval(120))
        _ = consume(engine, into: &presentation)
        XCTAssertEqual(engine.reminder?.id, id)
        XCTAssertEqual(engine.reminder?.postponements, 1)
        XCTAssertNotNil(presentation.expandedSize)
        XCTAssertFalse(presentation.isCollapsed)
    }

    func testLongReminderReplacementAndManualStartAlwaysExpand() throws {
        let engine = Engine(settings: settings(manual: true), now: now)
        var presentation = GentleReminderPresentation()
        engine.tick(seconds: 1200, now: now)
        _ = consume(engine, into: &presentation)
        let shortID = try XCTUnwrap(engine.reminder?.id)
        presentation.setCollapsed(true)
        engine.tick(seconds: 2400, now: now.addingTimeInterval(2400))
        _ = consume(engine, into: &presentation)
        XCTAssertEqual(engine.reminder?.kind, .long)
        XCTAssertNotEqual(engine.reminder?.id, shortID)
        XCTAssertFalse(presentation.isCollapsed)
        presentation.setCollapsed(true)
        engine.startNow(.short, now: now.addingTimeInterval(2400))
        _ = consume(engine, into: &presentation)
        XCTAssertEqual(engine.reminder?.kind, .short)
        XCTAssertTrue(engine.isResting)
        XCTAssertFalse(presentation.isCollapsed)
    }

    func testSkipEndAndPauseClearCollapsedPresentation() {
        for action in ["skip", "end", "pause"] {
            let engine = Engine(settings: settings(), now: now)
            var presentation = GentleReminderPresentation()
            engine.tick(seconds: 1200, now: now)
            _ = consume(engine, into: &presentation)
            presentation.setCollapsed(true)
            switch action {
            case "skip": engine.skip(now: now)
            case "end": engine.finish(now: now)
            default: engine.setPause(.indefinite, now: now)
            }
            _ = consume(engine, into: &presentation)
            XCTAssertNil(presentation.expandedSize, action)
            XCTAssertFalse(presentation.isCollapsed, action)
        }
    }

    func testSettingsAndNonPresentationEffectsDoNotResetCapturedSizeOrCollapse() {
        var settings = settings()
        settings.gentleReminderSize = .mini
        var presentation = GentleReminderPresentation()
        let reminder = Reminder(kind: .short, target: 20)
        presentation.apply(.show(reminder), settings: settings)
        presentation.setCollapsed(true)
        settings.gentleReminderSize = .normal
        settings.language = "ja"
        settings.gentleReminderPosition = .bottomRight
        presentation.apply(.warning(.short), settings: settings)
        XCTAssertEqual(presentation.expandedSize, .mini)
        XCTAssertTrue(presentation.isCollapsed)
        presentation.apply(.show(reminder), settings: settings)
        XCTAssertEqual(presentation.expandedSize, .normal)
        XCTAssertFalse(presentation.isCollapsed)
        settings.style = .overlay
        presentation.apply(.show(reminder), settings: settings)
        XCTAssertNil(presentation.expandedSize)
        presentation.setCollapsed(true)
        XCTAssertFalse(presentation.isCollapsed)
    }

    func testPreviewStartsExpandedAndEndsWithoutEngineState() {
        var presentation = GentleReminderPresentation()
        presentation.begin(size: .small)
        presentation.setCollapsed(true)
        presentation.end()
        XCTAssertNil(presentation.expandedSize)
        presentation.begin(size: .mini)
        XCTAssertFalse(presentation.isCollapsed)
        XCTAssertEqual(presentation.expandedSize, .mini)
    }

    func testCollapseGeometryKeepsAllNineAnchorsOnOffsetDisplays() {
        for screen in [NSRect(x: -1200, y: 100, width: 1000, height: 700),
                       NSRect(x: 500, y: -700, width: 500, height: 360)] {
            for position in GentleReminderPosition.allCases {
                let expanded = GentleReminderPlacement.frame(size: NSSize(width: 420, height: 280),
                    in: screen, position: position)
                let collapsed = GentleReminderPlacement.frame(size: NSSize(width: 240, height: 56),
                    in: screen, position: position)
                XCTAssertTrue(screen.contains(expanded))
                XCTAssertTrue(screen.contains(collapsed))
                switch position {
                case .topLeft, .middleLeft, .bottomLeft: XCTAssertEqual(expanded.minX, collapsed.minX)
                case .topCenter, .center, .bottomCenter: XCTAssertEqual(expanded.midX, collapsed.midX)
                case .topRight, .middleRight, .bottomRight: XCTAssertEqual(expanded.maxX, collapsed.maxX)
                }
                switch position {
                case .topLeft, .topCenter, .topRight: XCTAssertEqual(expanded.maxY, collapsed.maxY)
                case .middleLeft, .center, .middleRight: XCTAssertEqual(expanded.midY, collapsed.midY)
                case .bottomLeft, .bottomCenter, .bottomRight: XCTAssertEqual(expanded.minY, collapsed.minY)
                }
            }
        }
    }

    func testCompactStatusDistinguishesWaitingRunningAndPreviewInEveryLocale() {
        let previous = L10n.language
        defer { L10n.language = previous }
        for language in ["zh-Hans", "zh-Hant", "en", "ja", "ko"] {
            L10n.language = language
            let waiting = GentleReminderPresentation.status(preview: false, resting: false, remaining: 20)
            let running = GentleReminderPresentation.status(preview: false, resting: true, remaining: 18)
            let preview = GentleReminderPresentation.status(preview: true, resting: false, remaining: 20)
            XCTAssertEqual(waiting, L10n.text("rest.compact_waiting"))
            XCTAssertFalse(waiting.contains("00:20"))
            XCTAssertTrue(running.contains("00:18"))
            XCTAssertTrue(preview.contains("00:05"))
            XCTAssertNotEqual(waiting, running)
            for key in ["rest.collapse", "rest.expand"] { XCTAssertNotEqual(L10n.text(key), key) }
        }
    }
}
