import AppKit
import SwiftUI

enum SettingsWindowLayout {
    // Captured settings window, including its 52-point titlebar and toolbar.
    static let minimumFrameSize = NSSize(width: 890, height: 708)
    static let minimumContentSize = NSSize(width: 890, height: 656)
}

enum SettingsPalette {
    static let content = adaptiveColor(red: 234, green: 235, blue: 236)
    static let sidebar = adaptiveColor(red: 222, green: 223, blue: 224)
    // Match the raised background of native grouped Form cards in dark mode.
    static let card = adaptiveColor(red: 230, green: 231, blue: 232,
                                    dark: NSColor(srgbRed: 53 / 255, green: 53 / 255, blue: 53 / 255, alpha: 1))

    private static func adaptiveColor(red: CGFloat, green: CGFloat, blue: CGFloat, dark: NSColor = .windowBackgroundColor) -> NSColor {
        NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
                return dark
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

/// Observe the detail's native scroll views, including grouped Forms, on macOS 13.
struct SettingsScrollObserver: NSViewRepresentable {
    let onChange: (Bool) -> Void
    func makeNSView(context: Context) -> SettingsScrollTrackingView {
        SettingsScrollTrackingView(onChange: onChange)
    }
    func updateNSView(_ view: SettingsScrollTrackingView, context: Context) {
        view.onChange = onChange
        view.scheduleRefresh()
    }
}

final class SettingsScrollTrackingView: NSView {
    var onChange: (Bool) -> Void
    private var tokens: [NSObjectProtocol] = []
    private var scrollViews: [NSScrollView] = []
    private var refreshPending = false
    private var previous: Bool?
    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleRefresh()
    }
    func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshPending = false
            self.refresh()
        }
    }
    private func refresh() {
        guard window != nil else { return }
        var root: NSView = self
        while let parent = root.superview, !(parent is NSSplitView) { root = parent }
        func collect(_ view: NSView) -> [NSScrollView] {
            // Nested thumbnail grids do not determine the page's scroll position.
            if let scroll = view as? NSScrollView { return [scroll] }
            return view.subviews.flatMap(collect)
        }
        let found = collect(root)
        if found.map(ObjectIdentifier.init) != scrollViews.map(ObjectIdentifier.init) {
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens = []
            scrollViews = found
            for scroll in found {
                scroll.contentView.postsBoundsChangedNotifications = true
                tokens.append(NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
                ) { [weak self] _ in self?.report() })
            }
        }
        report()
    }
    private func report() {
        let scrolled = scrollViews.contains { scroll in
            guard let document = scroll.documentView else { return false }
            let visible = document.convert(scroll.contentView.bounds, from: scroll.contentView)
            let offset = document.isFlipped ? visible.minY - document.bounds.minY : document.bounds.maxY - visible.maxY
            return offset > 1
        }
        guard previous != scrolled else { return }
        previous = scrolled
        onChange(scrolled)
    }
}
