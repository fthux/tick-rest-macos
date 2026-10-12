import Foundation
import TickRestCore

/// Transient display state. A repeated .show is a new presentation even when
/// postponement retains the same reminder ID; screen rebuilds do not apply .show.
struct GentleReminderPresentation {
    private(set) var expandedSize: GentleReminderSize?
    private(set) var isCollapsed = false
    static let collapsedWidth: CGFloat = 240
    static let collapsedHeight: CGFloat = 56

    var width: CGFloat {
        isCollapsed ? Self.collapsedWidth : GentleCardLayout(size: expandedSize ?? .normal).width
    }

    mutating func begin(size: GentleReminderSize) {
        expandedSize = size
        isCollapsed = false
    }

    mutating func end() {
        expandedSize = nil
        isCollapsed = false
    }

    mutating func setCollapsed(_ value: Bool) {
        guard expandedSize != nil else { return }
        isCollapsed = value
    }

    mutating func apply(_ effect: EngineEffect, settings: Settings) {
        switch effect {
        case .show:
            if settings.style == .gentle { begin(size: settings.gentleReminderSize) }
            else { end() }
        case .hide: end()
        default: break
        }
    }

    static func status(preview: Bool, resting: Bool, remaining: Double) -> String {
        if preview { return L10n.text("rest.compact_preview", L10n.clock(5)) }
        if resting { return L10n.text("rest.compact_running", L10n.clock(remaining)) }
        return L10n.text("rest.compact_waiting")
    }
}
