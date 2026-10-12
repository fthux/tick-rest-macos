import AppKit
import CoreGraphics
import TickRestCore

struct ConnectedDisplay: Identifiable {
    let id: String
    let name: String

    static func identifier(for screen: NSScreen) -> String {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        guard let number else { return "screen-\(screen.localizedName)" }
        let displayID = CGDirectDisplayID(number.uint32Value)
        if let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() {
            return CFUUIDCreateString(nil, uuid) as String
        }
        return "display-\(displayID)"
    }

    static var current: [ConnectedDisplay] {
        NSScreen.screens.map { screen in
            ConnectedDisplay(id: identifier(for: screen), name: screen.localizedName)
        }
    }
}

/// Resolves the same targets for previews, real reminders and display changes.
/// Pure inputs allow multi-display and unplug/reconnect tests without windows.
struct ReminderScreenSelection: Equatable {
    let targets: [Int]
    let primary: Int?

    static func resolve(settings: Settings, displayIDs: [String], currentIndex: Int?) -> Self {
        guard !displayIDs.isEmpty else { return Self(targets: [], primary: nil) }
        let current = currentIndex.flatMap { displayIDs.indices.contains($0) ? $0 : nil } ?? 0
        guard settings.style == .overlay else { return Self(targets: [current], primary: current) }
        switch settings.displayScope {
        case .all: return Self(targets: Array(displayIDs.indices), primary: current)
        case .current: return Self(targets: [current], primary: current)
        case .selected:
            let selected = settings.selectedDisplayID.flatMap { displayIDs.firstIndex(of: $0) } ?? current
            return Self(targets: [selected], primary: selected)
        }
    }
}
