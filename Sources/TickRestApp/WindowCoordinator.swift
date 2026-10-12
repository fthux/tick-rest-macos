import AppKit
import SwiftUI
import TickRestCore

final class ReminderPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

enum GentleReminderPlacement {
    static func frame(size: NSSize, in visibleFrame: NSRect, position: GentleReminderPosition) -> NSRect {
        // Reduce margins on small displays and respect displays with nonzero origins.
        let horizontalSpace = max(0, visibleFrame.width - size.width)
        let verticalSpace = max(0, visibleFrame.height - size.height)
        let horizontalMargin = min(32, horizontalSpace / 2)
        let verticalMargin = min(30, verticalSpace / 2)
        let x: CGFloat
        switch position {
        case .topLeft, .middleLeft, .bottomLeft: x = visibleFrame.minX + horizontalMargin
        case .topCenter, .center, .bottomCenter: x = visibleFrame.minX + horizontalSpace / 2
        case .topRight, .middleRight, .bottomRight: x = visibleFrame.minX + horizontalSpace - horizontalMargin
        }
        let y: CGFloat
        switch position {
        case .topLeft, .topCenter, .topRight: y = visibleFrame.minY + verticalSpace - verticalMargin
        case .middleLeft, .center, .middleRight: y = visibleFrame.minY + verticalSpace / 2
        case .bottomLeft, .bottomCenter, .bottomRight: y = visibleFrame.minY + verticalMargin
        }
        // AppKit rounds window origins to whole points; use the same coordinates
        // so refresh does not repeatedly try to move a centered card by half a point.
        return NSRect(origin: NSPoint(x: floor(x), y: floor(y)), size: size)
    }
}

final class WindowCoordinator {
    let model: AppController
    var showSettings: (() -> Void)?
    private var panels: [NSPanel] = []
    private var warning: NSPanel?
    private var warningWork: DispatchWorkItem?
    private var previewWork: DispatchWorkItem?
    private var priorApplication: NSRunningApplication?
    private var displayObserver: NSObjectProtocol?
    private var isPreview = false
    private var shownStyle: ReminderStyle?
    private var gentlePresentation = GentleReminderPresentation()
    init(model: AppController) {
        self.model = model
        displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, !self.panels.isEmpty, !self.isPreview, let r = self.model.engine.reminder else { return }
            self.show(r, preview: false, rebuilding: true)
        }
    }
    func apply(_ effects: [EngineEffect]) {
        for effect in effects {
            gentlePresentation.apply(effect, settings: model.settings)
            switch effect {
            case .warning(let kind): model.notifyWarning(kind) { [weak self] in self?.showWarning(kind) }
            case .show(let r): show(r, preview: false)
            case .hide: hide(); model.removeNotifications()
            case .completed: if model.settings.sound { model.playReminderSound() }
            }
        }
    }
    func refresh() {
        if shownStyle == .overlay {
            panels.forEach { $0.backgroundColor = overlayBackgroundColor }
        }
        // Resize the actual panel in both dimensions, including its hit area.
        if shownStyle == .gentle, let panel = panels.first, let hosting = panel.contentView,
           let screen = panel.screen ?? currentScreen {
            hosting.layoutSubtreeIfNeeded()
            let height = ceil(hosting.fittingSize.height)
            if height > 0 {
                let frame = GentleReminderPlacement.frame(size: NSSize(width: gentlePresentation.width, height: height),
                    in: screen.visibleFrame, position: model.settings.gentleReminderPosition)
                if panel.frame != frame { panel.setFrame(frame, display: true) }
            }
        }
        if !isPreview, shownStyle == .overlay, model.engine.isResting, let reminder = model.engine.reminder {
            panels.forEach { $0.title = L10n.text("state.resting", reminder.title, L10n.clock(reminder.target - reminder.elapsed)) }
        }
    }
    private var currentScreen: NSScreen? { NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first }
    func preview() {
        guard model.engine.reminder == nil else { return }
        if model.settings.style == .gentle { gentlePresentation.begin(size: model.settings.gentleReminderSize) }
        else { gentlePresentation.end() }
        show(model.settings.previewReminder, preview: true)
        let task = DispatchWorkItem { [weak self] in self?.hide() }; previewWork = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: task)
    }
    private func show(_ r: Reminder, preview: Bool, rebuilding: Bool = false) {
        let previous = priorApplication
        let previousScreen = rebuilding ? panels.first?.screen : nil
        hide(restoreFocus: false, preservingGentlePresentation: true)
        isPreview = preview; shownStyle = model.settings.style
        priorApplication = previous ?? NSWorkspace.shared.frontmostApplication
        guard let screen = previousScreen.flatMap({ NSScreen.screens.contains($0) ? $0 : nil }) ?? currentScreen else { return }
        if model.settings.style == .gentle {
            // Capture the size for this presentation; settings apply to the next card.
            if gentlePresentation.expandedSize == nil { gentlePresentation.begin(size: model.settings.gentleReminderSize) }
            let hosting = NSHostingView(rootView: gentleCard())
            hosting.sizingOptions = [.intrinsicContentSize]
            let size = NSSize(width: gentlePresentation.width, height: ceil(hosting.fittingSize.height))
            let rect = GentleReminderPlacement.frame(size: size, in: screen.visibleFrame,
                                                     position: model.settings.gentleReminderPosition)
            let panel = makePanel(frame: rect, overlay: false)
            panel.contentView = hosting
            panel.setContentSize(size)
            panel.orderFrontRegardless(); panels = [panel]
        } else {
            let screens = model.settings.displayScope == .all ? NSScreen.screens : [screen]
            for target in screens {
                let panel = makePanel(frame: target.frame, overlay: true)
                panel.contentView = NSHostingView(rootView: OverlayView(model: model, preview: preview, primary: target == screen, previewEnd: { [weak self] in self?.hide() }))
                panel.orderFrontRegardless(); panels.append(panel)
                if target == screen { panel.makeKey() }
            }
        }
        if model.settings.sound && !preview && !rebuilding { model.playReminderSound() }
    }
    private func gentleCard() -> RestCard {
        RestCard(model: model, size: gentlePresentation.expandedSize ?? model.settings.gentleReminderSize,
                 preview: isPreview, previewEnd: { [weak self] in self?.hide() },
                 collapsed: gentlePresentation.isCollapsed,
                 setCollapsed: { [weak self] value in self?.setGentleCollapsed(value) })
    }
    private func setGentleCollapsed(_ value: Bool) {
        guard shownStyle == .gentle,
              let hosting = panels.first?.contentView as? NSHostingView<RestCard> else { return }
        gentlePresentation.setCollapsed(value)
        hosting.rootView = gentleCard()
        refresh()
        // SwiftUI may commit intrinsic sizing after the click's transaction.
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }
    private func makePanel(frame: NSRect, overlay: Bool) -> ReminderPanel {
        let panel = ReminderPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.level = overlay ? .screenSaver : .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = overlay; panel.backgroundColor = overlay ? overlayBackgroundColor : .clear
        panel.hasShadow = !overlay
        return panel
    }
    private var overlayBackgroundColor: NSColor {
        let color = model.settings.overlayBackgroundColor
        return NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
    }
    private func showWarning(_ kind: BreakKind) {
        guard !model.engine.suppressed, !model.engine.away, model.engine.pause == nil, let screen = currentScreen else { return }
        warning?.close(); warningWork?.cancel()
        let panel = makePanel(frame: NSRect(x: screen.visibleFrame.maxX - 420, y: screen.visibleFrame.maxY - 130, width: 390, height: 105), overlay: false)
        panel.contentView = NSHostingView(rootView: WarningView(model: model, kind: kind))
        warning = panel; panel.orderFrontRegardless()
        let task = DispatchWorkItem { [weak self] in self?.warning?.close(); self?.warning = nil }
        warningWork = task; DispatchQueue.main.asyncAfter(deadline: .now() + max(1, model.settings.prewarning), execute: task)
    }
    func hide(restoreFocus: Bool = true, preservingGentlePresentation: Bool = false) {
        warningWork?.cancel(); previewWork?.cancel(); warning?.close(); warning = nil
        let hadOverlay = shownStyle == .overlay && !panels.isEmpty
        panels.forEach { $0.close() }; panels = []; isPreview = false; shownStyle = nil
        if !preservingGentlePresentation { gentlePresentation.end() }
        if restoreFocus && hadOverlay, let prior = priorApplication, !prior.isTerminated,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            prior.activate(options: [])
        }
        priorApplication = nil
    }
}
