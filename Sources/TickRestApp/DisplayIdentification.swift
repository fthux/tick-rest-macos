import AppKit
import SwiftUI
import TickRestCore

struct DisplayIdentificationTarget {
    let display: ConnectedDisplay
    let frame: NSRect

    static func connected(id: String) -> Self? {
        guard let screen = NSScreen.screens.first(where: { ConnectedDisplay.identifier(for: $0) == id }) else { return nil }
        return Self(display: ConnectedDisplay(id: id, name: screen.localizedName), frame: screen.frame)
    }
}

/// Owns only the transient identification hint, independently of rest windows.
/// Injected presentation and scheduling let tests run without creating windows.
final class DisplayIdentificationController {
    typealias Resolve = (String) -> DisplayIdentificationTarget?
    typealias Present = (DisplayIdentificationTarget) -> (() -> Void)
    typealias Schedule = (TimeInterval, @escaping () -> Void) -> (() -> Void)

    private let resolve: Resolve
    private let present: Present
    private let schedule: Schedule
    private var dismissPanel: (() -> Void)?
    private var cancelTimeout: (() -> Void)?
    private var generation = UUID()

    init(resolve: @escaping Resolve = DisplayIdentificationTarget.connected,
         present: @escaping Present = DisplayIdentificationController.showPanel,
         schedule: @escaping Schedule = DisplayIdentificationController.scheduleTimeout) {
        self.resolve = resolve; self.present = present; self.schedule = schedule
    }

    func identify(_ displayID: String?) {
        clear()
        // A disconnected target must never identify a different display.
        guard let displayID, let target = resolve(displayID) else { return }
        dismissPanel = present(target)
        let token = generation
        cancelTimeout = schedule(3) { [weak self] in
            guard let self, self.generation == token else { return }
            self.clear()
        }
    }

    func clear() {
        generation = UUID()
        cancelTimeout?(); cancelTimeout = nil
        dismissPanel?(); dismissPanel = nil
    }

    deinit { cancelTimeout?(); dismissPanel?() }

    private static func scheduleTimeout(after delay: TimeInterval, action: @escaping () -> Void) -> () -> Void {
        let work = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        return { work.cancel() }
    }

    private static func showPanel(_ target: DisplayIdentificationTarget) -> () -> Void {
        let panel = DisplayIdentificationPanel(contentRect: target.frame,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.hidesOnDeactivate = false; panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: DisplayIdentificationView(name: target.display.name))
        panel.setFrame(target.frame, display: true)
        panel.orderFrontRegardless()
        return { panel.close() }
    }
}

private final class DisplayIdentificationPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct DisplayIdentificationView: View {
    let name: String
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.orange, lineWidth: 8).padding(8)
            VStack(spacing: 16) {
                Image(systemName: "display").font(.system(size: 44)).foregroundStyle(.orange)
                Text(L10n.text("displays.identifying")).font(.title2.bold())
                Text(name).font(.title3)
            }
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(32)
            .background(Color.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 18))
            .padding(32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
