import XCTest
import TickRestCore
@testable import TickRestApp

final class ReminderAppearanceTests: XCTestCase {
    func testOverlayButtonContrastAcrossRGBColorsAndInteractionStates() {
        func luminance(_ color: SRGBColor) -> Double {
            func linear(_ value: Double) -> Double {
                value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
        }
        for red in stride(from: 0.0, through: 1.0, by: 0.05) {
            for green in stride(from: 0.0, through: 1.0, by: 0.05) {
                for blue in stride(from: 0.0, through: 1.0, by: 0.05) {
                    let background = SRGBColor(red: red, green: green, blue: blue)
                    let palette = OverlayPalette(background: background)
                    for prominent in [false, true] {
                        for highlighted in [false, true] {
                            let surface = palette.buttonBackgroundComponents(prominent: prominent, highlighted: highlighted)
                            let brightness = luminance(surface)
                            let contrast = palette.usesDarkText ? (brightness + 0.05) / 0.05 : 1.05 / (brightness + 0.05)
                            XCTAssertGreaterThanOrEqual(contrast, 4.5, "Unreadable button on \(background)")
                        }
                    }
                }
            }
        }
    }
}
