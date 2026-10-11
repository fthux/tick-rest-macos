import AppKit
import SwiftUI
import TickRestCore

final class ReminderPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var escape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { escape?() }
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
    init(model: AppController) {
        self.model = model
        displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, !self.panels.isEmpty, !self.isPreview, let r = self.model.engine.reminder else { return }
            self.show(r, preview: false)
        }
    }
    func apply(_ effects: [EngineEffect]) {
        for effect in effects {
            switch effect {
            case .warning(let kind): model.notifyWarning(kind) { [weak self] in self?.showWarning(kind) }
            case .show(let r): show(r, preview: false)
            case .hide: hide(); model.removeNotifications()
            case .completed: if model.settings.sound { model.playReminderSound() }
            }
        }
    }
    func refresh() {
        if !isPreview, shownStyle == .overlay, model.engine.isResting, let reminder = model.engine.reminder {
            panels.forEach { $0.title = L10n.text("state.resting", reminder.kind.title, L10n.clock(reminder.target - reminder.elapsed)) }
        }
    }
    private var currentScreen: NSScreen? { NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first }
    func preview() {
        guard model.engine.reminder == nil else { return }
        show(Reminder(kind: .short, target: 5), preview: true)
        let task = DispatchWorkItem { [weak self] in self?.hide() }; previewWork = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: task)
    }
    private func show(_ r: Reminder, preview: Bool) {
        let previous = priorApplication
        hide(restoreFocus: false)
        isPreview = preview; shownStyle = model.settings.style
        priorApplication = previous ?? NSWorkspace.shared.frontmostApplication
        guard let screen = currentScreen else { return }
        if model.settings.style == .gentle {
            let hosting = NSHostingView(rootView: RestCard(model: model, preview: preview, previewEnd: { [weak self] in self?.hide() }).frame(width: 420))
            hosting.sizingOptions = [.intrinsicContentSize]
            let size = NSSize(width: 420, height: ceil(hosting.fittingSize.height))
            let rect = NSRect(x: screen.visibleFrame.maxX - size.width - 32, y: screen.visibleFrame.maxY - size.height - 30, width: size.width, height: size.height)
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
        if model.settings.sound && !preview { model.playReminderSound() }
    }
    private func makePanel(frame: NSRect, overlay: Bool) -> ReminderPanel {
        let panel = ReminderPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.level = overlay ? .screenSaver : .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = overlay; panel.backgroundColor = overlay ? NSColor(calibratedRed: 0.10, green: 0.18, blue: 0.15, alpha: 1) : .clear
        panel.hasShadow = !overlay
        panel.escape = { [weak self] in
            guard let self else { return }
            if self.isPreview { self.hide() }
            else { self.model.action { $0.skip(now: Date()) } }
        }
        return panel
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
    func hide(restoreFocus: Bool = true) {
        warningWork?.cancel(); previewWork?.cancel(); warning?.close(); warning = nil
        let hadOverlay = shownStyle == .overlay && !panels.isEmpty
        panels.forEach { $0.close() }; panels = []; isPreview = false; shownStyle = nil
        if restoreFocus && hadOverlay, let prior = priorApplication, !prior.isTerminated,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            prior.activate(options: [])
        }
        priorApplication = nil
    }
}
