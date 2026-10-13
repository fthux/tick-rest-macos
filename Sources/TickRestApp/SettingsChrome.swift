import AppKit
import SwiftUI

enum SettingsPalette {
    static let content = adaptiveColor(red: 234, green: 235, blue: 236)
    static let sidebar = adaptiveColor(red: 222, green: 223, blue: 224)

    private static func adaptiveColor(red: CGFloat, green: CGFloat, blue: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
                return .windowBackgroundColor
            }
            return NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
        }
    }
}

struct SettingsSidebarBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        if colorScheme == .dark {
            Color(nsColor: SettingsPalette.sidebar)
        } else {
            LinearGradient(stops: [
                .init(color: Color(nsColor: SettingsPalette.sidebar), location: 0),
                .init(color: Color(nsColor: SettingsPalette.sidebar), location: 0.84),
                .init(color: Color(.sRGB, red: 215 / 255, green: 217 / 255, blue: 221 / 255), location: 0.88),
                .init(color: Color(.sRGB, red: 203 / 255, green: 208 / 255, blue: 215 / 255), location: 0.92),
                .init(color: Color(.sRGB, red: 196 / 255, green: 202 / 255, blue: 210 / 255), location: 1)
            ], startPoint: .top, endPoint: .bottom)
        }
    }
}
