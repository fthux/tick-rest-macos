import AppKit
import XCTest
import TickRestCore
@testable import TickRestUpdater

final class UpdaterCompletionTests: XCTestCase {
    @MainActor func testManualSuccessFillsProgressAndClosesWithoutAnotherClick() async throws {
        _ = NSApplication.shared
        var terminations = 0
        let updater = UpdaterDelegate(completionDelay: 0.01, terminate: { terminations += 1 })
        updater.makeWindow(show: false)
        defer { updater.window.close() }
        updater.setState(UpdateJobState(.relaunching))
        XCTAssertLessThan(updater.progress.doubleValue, updater.progress.maxValue)
        XCTAssertEqual(terminations, 0)

        try updater.complete(automatic: false)
        XCTAssertFalse(updater.progress.isIndeterminate)
        XCTAssertEqual(updater.progress.doubleValue, updater.progress.maxValue)
        XCTAssertEqual(updater.heading.stringValue, L10n.text("update.stage.completed"))
        XCTAssertEqual(updater.detail.stringValue, L10n.text("update.completed_help"))
        XCTAssertEqual(updater.action.title, L10n.text("common.close"))
        XCTAssertTrue(updater.action.isEnabled)
        XCTAssertEqual(terminations, 0, "Show the completed state before automatically closing")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(terminations, 1)
    }

    @MainActor func testAutomaticSuccessExitsImmediately() throws {
        _ = NSApplication.shared
        var terminations = 0
        let updater = UpdaterDelegate(terminate: { terminations += 1 })
        try updater.complete(automatic: true)
        XCTAssertEqual(terminations, 1)
    }

    @MainActor func testStagesAdvanceAndNeverFinishBeforeRelaunchAcknowledgement() async throws {
        _ = NSApplication.shared
        var terminations = 0
        let updater = UpdaterDelegate(completionDelay: 0.01, terminate: { terminations += 1 })
        updater.makeWindow(show: false)
        defer { updater.window.close() }
        let phases: [UpdateJobState.Phase] = [.preparing, .refreshing, .downloading, .waiting,
                                             .installing, .verifying, .relaunching]
        var previous = 0.0
        for phase in phases {
            updater.setState(UpdateJobState(phase))
            XCTAssertGreaterThan(updater.progress.doubleValue, previous)
            XCTAssertLessThan(updater.progress.doubleValue, updater.progress.maxValue)
            XCTAssertEqual(updater.action.isEnabled, phase.canCancel)
            previous = updater.progress.doubleValue
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(terminations, 0, "Launching alone must not report a completed update or close the helper")
    }

    @MainActor func testFailureAndCancellationStayOpenAndKeepLastProgress() async throws {
        _ = NSApplication.shared
        for phase: UpdateJobState.Phase in [.failed, .cancelled] {
            var terminations = 0
            let updater = UpdaterDelegate(completionDelay: 0.01, terminate: { terminations += 1 })
            updater.makeWindow(show: false)
            defer { updater.window.close() }
            updater.setState(UpdateJobState(.downloading))
            let progress = updater.progress.doubleValue
            updater.setState(UpdateJobState(phase, failure: phase == .failed ? .command : .cancelled))
            XCTAssertEqual(updater.progress.doubleValue, progress)
            XCTAssertEqual(updater.detail.stringValue, L10n.text("update.finished_help"))
            XCTAssertTrue(updater.action.isEnabled)
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertEqual(terminations, 0)
        }
    }

    @MainActor func testFailureCancelsPendingSuccessDismissal() async throws {
        _ = NSApplication.shared
        var terminations = 0
        let updater = UpdaterDelegate(completionDelay: 0.01, terminate: { terminations += 1 })
        updater.makeWindow(show: false)
        defer { updater.window.close() }
        try updater.complete(automatic: false)
        updater.setState(UpdateJobState(.failed, failure: .permissions))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(terminations, 0)
    }

    @MainActor func testCompletedWindowRendersInEveryLanguage() throws {
        _ = NSApplication.shared
        let language = L10n.language
        defer { L10n.language = language }
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/updater-completion")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for language in ["en", "zh-Hans", "zh-Hant", "ja", "ko"] {
            L10n.language = language
            let updater = UpdaterDelegate(terminate: {})
            updater.makeWindow(show: false)
            defer { updater.window.close() }
            updater.window.appearance = NSAppearance(named: .aqua)
            updater.setState(UpdateJobState(.completed))
            XCTAssertEqual(updater.progress.doubleValue, 1)
            XCTAssertNotEqual(updater.detail.stringValue, "update.completed_help")
            let view = try XCTUnwrap(updater.window.contentView?.superview)
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent(language + ".png"))
        }
    }
}
