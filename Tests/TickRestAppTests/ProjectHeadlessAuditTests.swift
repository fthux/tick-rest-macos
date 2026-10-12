import Foundation
import XCTest
import TickRestCore
@testable import TickRestApp

/// Pure geometry and resource formatting only; never initialize NSApplication,
/// construct a window, invoke AppDelegate or access a user's data directory.
final class ProjectHeadlessAuditTests: XCTestCase {
    func testNormalCardMustFitAWorkAreaSmallerThanItsPreferredSize() {
        let workArea = CGRect(x: -400, y: 100, width: 400, height: 300)
        let requested = CGSize(width: GentleCardLayout(size: .normal).width, height: 320)
        for position in GentleReminderPosition.allCases {
            let frame = GentleReminderPlacement.frame(size: requested, in: workArea, position: position)
            XCTAssertTrue(workArea.contains(frame), "Oversized card extends outside the work area at \(position)")
        }
    }

    func testCardsFitAllAnchorsWithFractionalOriginsAndNarrowWorkAreas() {
        let workAreas = [
            CGRect(x: -399.75, y: 100.5, width: 400, height: 300),
            CGRect(x: 1500, y: -200, width: 220, height: 48),
            CGRect(x: -1200, y: -700, width: 1000, height: 700)
        ]
        let sizes = [CGSize(width: 420, height: 700), CGSize(width: 340, height: 260),
                     CGSize(width: 280, height: 180), CGSize(width: 240, height: 56)]
        for area in workAreas {
            for preferred in sizes {
                let fitted = GentleReminderPlacement.fittedSize(preferred, in: area.size)
                XCTAssertEqual(fitted.width, min(preferred.width, area.width))
                XCTAssertEqual(fitted.height, min(preferred.height, area.height))
                for position in GentleReminderPosition.allCases {
                    let frame = GentleReminderPlacement.frame(size: preferred, in: area, position: position)
                    XCTAssertEqual(frame.size, fitted)
                    XCTAssertTrue(area.contains(frame), "\(position): \(area) must contain \(frame)")
                }
            }
        }
    }

    @MainActor
    func testEveryTranslationCanFormatItsActualPlaceholderTypes() throws {
        let previous = L10n.language
        defer { L10n.language = previous }
        var total = 0
        var referenceKeys: Set<String>?
        for language in ["en", "zh-Hans", "zh-Hant", "ja", "ko"] {
            L10n.language = language
            let identifier = try XCTUnwrap(L10n.availableLanguages.first { $0.caseInsensitiveCompare(language) == .orderedSame })
            let bundlePath = try XCTUnwrap(L10n.resourceBundle.path(forResource: identifier, ofType: "lproj"))
            let directory = URL(fileURLWithPath: bundlePath)
            let data = try Data(contentsOf: directory.appendingPathComponent("Localizable.strings"))
            let values = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
            let keys = Set(values.keys)
            if let referenceKeys { XCTAssertEqual(keys, referenceKeys, language) }
            else { referenceKeys = keys }
            let regex = try NSRegularExpression(pattern: #"%(?!%)(?:\d+\$)?([@dfsu])"#)
            for (key, format) in values {
                let matches = regex.matches(in: format, range: NSRange(format.startIndex..., in: format))
                // All current translations use unnumbered string/integer
                // placeholders. Fail explicitly if future formats need more types.
                let args: [CVarArg] = matches.map { match in
                    let type = (format as NSString).substring(with: match.range(at: 1))
                    return type == "@" ? "Sample" as CVarArg : 3 as CVarArg
                }
                XCTAssertTrue(matches.allSatisfy {
                    ["@", "d"].contains((format as NSString).substring(with: $0.range(at: 1)))
                }, "Unsupported formatting fixture for \(key)")
                let branded = format.replacingOccurrences(of: "{appName}", with: AppIdentity.name)
                let rendered = args.isEmpty ? branded : String(format: branded, locale: L10n.locale, arguments: args)
                XCTAssertFalse(rendered.isEmpty, "\(language):\(key)")
                XCTAssertFalse(rendered.contains("{appName}"), "\(language):\(key)")
                XCTAssertNil(rendered.range(of: #"%(?:\d+\$)?[@dfsu]"#, options: .regularExpression), "\(language):\(key)")
                if args.isEmpty { XCTAssertEqual(L10n.text(key), branded, "\(language):\(key)") }
                total += 1
            }
        }
        XCTAssertEqual(total, try XCTUnwrap(referenceKeys).count * 5)
    }
}
