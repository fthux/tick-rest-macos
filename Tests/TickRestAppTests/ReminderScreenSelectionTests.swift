import XCTest
import TickRestCore
@testable import TickRestApp

/// Synthetic display identities only: no app, screens, windows or user store.
final class ReminderScreenSelectionTests: XCTestCase {
    private func resolve(_ scope: DisplayScope = .selected, selected: String? = "external",
                         ids: [String] = ["built-in", "external"], pointer: Int? = 0,
                         style: ReminderStyle = .overlay) -> ReminderScreenSelection {
        var settings = Settings()
        settings.style = style
        settings.displayScope = scope
        settings.selectedDisplayID = selected
        return .resolve(settings: settings, displayIDs: ids, currentIndex: pointer)
    }

    func testSelectedDisplayReceivesBothOverlayAndControlsWhenPointerIsElsewhere() {
        let selection = resolve()
        XCTAssertEqual(selection.targets, [1])
        XCTAssertEqual(selection.primary, 1)
    }

    func testDisplayIdentitySurvivesReorderingAndAnotherDisplayWithTheSameName() {
        let selection = resolve(ids: ["external", "built-in", "other-external"], pointer: 2)
        XCTAssertEqual(selection.targets, [0])
        XCTAssertEqual(selection.primary, 0)
    }

    func testUnplugFallsBackToPointerAndReconnectReturnsToSavedSelection() {
        XCTAssertEqual(resolve(ids: ["built-in", "other-external"], pointer: 1).targets, [1])
        XCTAssertEqual(resolve(ids: ["external", "other-external", "built-in"], pointer: 1).targets, [0])
    }

    func testAbsentSelectionAndUnknownIdentityFallBackWithoutCoveringEveryDisplay() {
        for id in [nil, "missing"] as [String?] {
            let selection = resolve(selected: id, pointer: 1)
            XCTAssertEqual(selection.targets, [1])
            XCTAssertEqual(selection.primary, 1)
        }
    }

    func testNoDisplaysAndInvalidPointerIndicesAreSafe() {
        XCTAssertEqual(resolve(ids: []), ReminderScreenSelection(targets: [], primary: nil))
        for pointer in [nil, -1, 9] as [Int?] {
            XCTAssertEqual(resolve(selected: nil, pointer: pointer).targets, [0])
        }
    }

    func testExistingAllAndPointerScopesIgnoreSavedTarget() {
        XCTAssertEqual(resolve(.all, pointer: 0), ReminderScreenSelection(targets: [0, 1], primary: 0))
        XCTAssertEqual(resolve(.current, pointer: 0), ReminderScreenSelection(targets: [0], primary: 0))
    }

    func testGentleCardsContinueUsingOnlyThePointerDisplayInEveryScope() {
        for scope in DisplayScope.allCases {
            XCTAssertEqual(resolve(scope, style: .gentle), ReminderScreenSelection(targets: [0], primary: 0))
        }
    }
}
