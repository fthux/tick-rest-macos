import AppKit
import SwiftUI
import TickRestCore

final class ReminderPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

enum GentleReminderPlacement {
    static func fittedSize(_ size: NSSize, in available: NSSize) -> NSSize {
        NSSize(width: max(0, min(size.width, available.width)),
               height: max(0, min(size.height, available.height)))
    }

    static func frame(size: NSSize, in visibleFrame: NSRect, position: GentleReminderPosition) -> NSRect {
        let size = fittedSize(size, in: visibleFrame.size)
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
        let origin = NSPoint(x: max(visibleFrame.minX, min(visibleFrame.maxX - size.width, floor(x))),
                             y: max(visibleFrame.minY, min(visibleFrame.maxY - size.height, floor(y))))
        return NSRect(origin: origin, size: size)
    }
}

/// Keeps the entire card scrollable when its natural height exceeds the work area.
final class GentleCardViewport: NSScrollView {
    let hosting: NSHostingView<RestCard>
    private var fitted = NSSize.zero
    override var fittingSize: NSSize { fitted }

    init(card: RestCard) {
        hosting = NSHostingView(rootView: card)
        super.init(frame: .zero)
        hosting.sizingOptions = [.intrinsicContentSize]
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        documentView = hosting
    }

    required init?(coder: NSCoder) { nil }

    func fit(preferredWidth: CGFloat, in available: NSSize) -> NSSize {
        let width = GentleReminderPlacement.fittedSize(NSSize(width: preferredWidth, height: 0), in: available).width
        if hosting.rootView.maximumWidth != width { hosting.rootView.maximumWidth = width }
        hosting.setFrameSize(NSSize(width: width, height: hosting.frame.height))
        hosting.layoutSubtreeIfNeeded()
        let height = ceil(hosting.fittingSize.height)
        hosting.setFrameSize(NSSize(width: width, height: height))
        fitted = GentleReminderPlacement.fittedSize(NSSize(width: width, height: height), in: available)
        return fitted
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
    private let observations = NotificationObservations()
    private var isPreview = false
    private var shownStyle: ReminderStyle?
    private var gentlePresentation = GentleReminderPresentation()
    init(model: AppController) {
        self.model = model
        observations.observe(NotificationCenter.default, name: NSApplication.didChangeScreenParametersNotification) { [weak self] _ in
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
        if shownStyle == .gentle, let panel = panels.first, let viewport = panel.contentView as? GentleCardViewport,
           let screen = panel.screen ?? currentScreen {
            let size = viewport.fit(preferredWidth: gentlePresentation.width, in: screen.visibleFrame.size)
            if size.height > 0 {
                let frame = GentleReminderPlacement.frame(size: size,
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
            let viewport = GentleCardViewport(card: gentleCard())
            let size = viewport.fit(preferredWidth: gentlePresentation.width, in: screen.visibleFrame.size)
            let rect = GentleReminderPlacement.frame(size: size, in: screen.visibleFrame,
                                                     position: model.settings.gentleReminderPosition)
            let panel = makePanel(frame: rect, overlay: false)
            panel.contentView = viewport
            panel.setContentSize(rect.size)
            panel.orderFrontRegardless(); panels = [panel]
        } else {
            let screens = NSScreen.screens
            // On disconnection, fall back to the pointer rather than the old panel's screen.
            let fallback = model.settings.displayScope == .selected ? currentScreen : screen
            let selection = ReminderScreenSelection.resolve(settings: model.settings,
                displayIDs: screens.map { ConnectedDisplay.identifier(for: $0) },
                currentIndex: fallback.flatMap { screens.firstIndex(of: $0) })
            for index in selection.targets {
                let target = screens[index]
                let panel = makePanel(frame: target.frame, overlay: true)
                panel.contentView = NSHostingView(rootView: OverlayView(model: model, preview: preview, primary: index == selection.primary, previewEnd: { [weak self] in self?.hide() }))
                panel.orderFrontRegardless(); panels.append(panel)
                if index == selection.primary { panel.makeKey() }
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
              let viewport = panels.first?.contentView as? GentleCardViewport else { return }
        gentlePresentation.setCollapsed(value)
        viewport.hosting.rootView = gentleCard()
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
