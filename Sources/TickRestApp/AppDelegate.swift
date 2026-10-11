import AppKit
import Combine
import SwiftUI
import TickRestCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSToolbarDelegate {
    private var status: NSStatusItem!
    private var model: AppController!
    private var windows: WindowCoordinator!
    private var statusSubscription: AnyCancellable?
    private let statusDotRenderer = StatusDotRenderer()
    private var menuPlan: RestPlan?
    private var menuKinds: [BreakKind] = []
    private var menuResting = false
    private var menuRoundItem: NSMenuItem?
    private var menuStateItem: NSMenuItem?
    private var menuCountdownItems: [BreakKind: NSMenuItem] = [:]
    private var settingsWindow: NSWindow?
    private let settingsNavigation = SettingsNavigation()
    private var settingsPageSubscription: AnyCancellable?
    private var settingsVisibilitySubscription: AnyCancellable?
    private var languageSubscription: AnyCancellable?
    private weak var settingsSplitController: NSSplitViewController?
    private let sidebarToolbarIdentifier = NSToolbarItem.Identifier(AppIdentity.identifier("sidebar"))
    private let separatorToolbarIdentifier = NSToolbarItem.Identifier(AppIdentity.identifier("sidebarSeparator"))
    private let titleToolbarIdentifier = NSToolbarItem.Identifier(AppIdentity.identifier("pageTitle"))
    private let settingsTitleField = NSTextField(labelWithString: "")
    private var welcomeWindow: NSWindow?
    private var lockFD: Int32 = -1

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A per-user flock avoids duplicate schedulers without a persistent stale PID file.
        let lockDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent(AppIdentity.dataDirectory)
        try? FileManager.default.createDirectory(at: lockDirectory, withIntermediateDirectories: true)
        lockFD = open(lockDirectory.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            DistributedNotificationCenter.default().postNotificationName(NSNotification.Name(AppIdentity.identifier("showSettings")), object: nil)
            NSApp.terminate(nil); return
        }
        model = AppController(); windows = WindowCoordinator(model: model)
        windows.showSettings = { [weak self] in self?.openSettings() }
        model.onEffects = { [weak self] effects in self?.windows.apply(effects) }
        model.applyAppearance()
        settingsPageSubscription = settingsNavigation.$page.sink { [weak self] page in
            self?.settingsWindow?.title = page.title
            self?.settingsTitleField.stringValue = page.title
        }
        settingsVisibilitySubscription = settingsNavigation.$columnVisibility.sink { [weak self] visibility in
            self?.updateSidebarToolbarLabel(visibility)
        }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = NSImage(systemSymbolName: "leaf", accessibilityDescription: L10n.text("app.name"))
        let menu = NSMenu(); menu.delegate = self; status.menu = menu
        languageSubscription = model.$interfaceLanguage.removeDuplicates().dropFirst().sink { [weak self] _ in
            self?.updateStatus()
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(openSettings), name: NSNotification.Name(AppIdentity.identifier("showSettings")), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(previewRest), name: .previewRest, object: nil)
        model.begin(); updateStatus()
        // Published emits before mutation; refresh on the main queue after the engine/settings commit.
        // Revisions include each scheduler tick and explicit actions, so no second UI timer is needed.
        statusSubscription = model.$revision.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.updateStatus()
        }
        if !model.settings.onboardingComplete { openWelcome() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { openSettings(); return false }
    func applicationWillTerminate(_ notification: Notification) {
        statusSubscription?.cancel(); model?.consume(); model?.persist(); model?.removeNotifications()
        if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD) }
    }
    private func updateStatus() {
        guard model != nil, let button = status?.button else { return }
        let engine = model.engine
        let paused = engine.pause != nil || engine.away || engine.outsideSchedule
        let symbol = paused ? "pause.circle" : engine.isResting ? "leaf.fill" : "leaf"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: L10n.text("app.name"))
        let display = ReminderDisplay(engine: engine)
        let title = display.menuBarText
        button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        button.attributedTitle = statusDotRenderer.title(
            text: model.settings.showCountdown ? title : "",
            color: model.settings.showStatusDot ? model.settings.statusDotPalette[display.statusDotState] : nil,
            appearance: button.effectiveAppearance, font: button.font!
        )
        button.toolTip = L10n.text("app.name") + " — " + model.stateText
        button.setAccessibilityLabel(button.toolTip)
        if menuStateItem != nil, let menu = status.menu,
           menuPlan != model.settings.restPlan || menuKinds != engine.displayKinds || menuResting != engine.isResting { menuWillOpen(menu) }
        menuRoundItem?.title = L10n.text("plan.focus_state", engine.focusRound, model.settings.rounds)
        menuStateItem?.title = display.menuStateText
        for (kind, item) in menuCountdownItems {
            item.title = display.countdownText(for: kind)
        }
        settingsWindow?.title = settingsNavigation.page.title
        settingsTitleField.stringValue = settingsNavigation.page.title
        updateSidebarToolbarLabel(settingsNavigation.columnVisibility)
        welcomeWindow?.title = L10n.text("welcome.title")
        windows.refresh()
    }
    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems(); menuPlan = model.settings.restPlan
        menuKinds = model.engine.displayKinds; menuResting = model.engine.isResting
        menuCountdownItems.removeAll()
        let display = ReminderDisplay(engine: model.engine)
        menuStateItem = add(menu, display.menuStateText, nil)
        menuRoundItem = model.settings.timingModel == .rounds && model.engine.roundRestKind != nil
            ? add(menu, L10n.text("plan.focus_state", model.engine.focusRound, model.settings.rounds), nil) : nil
        if !model.engine.isResting {
            for kind in model.engine.displayKinds {
                menuCountdownItems[kind] = add(menu, display.countdownText(for: kind), nil)
            }
        }
        menu.addItem(.separator())
        if model.engine.isResting { add(menu, L10n.text("menu.end"), #selector(endRest)) }
        else {
            if model.settings.timingModel == .dual {
                if model.settings.shortEnabled { add(menu, L10n.text("menu.start_short"), #selector(startShort)) }
                if model.settings.longEnabled { add(menu, L10n.text("menu.start_long"), #selector(startLong)) }
            } else { add(menu, L10n.text("plan.start_now"), #selector(startCurrentBreak)) }
        }
        if model.engine.pause != nil { add(menu, L10n.text("menu.resume"), #selector(resume)) }
        else {
            let item = add(menu, L10n.text("menu.pause"), nil)
            item.isEnabled = true
            let sub = NSMenu()
            add(sub, L10n.text("menu.pause_15"), #selector(pause15))
            add(sub, L10n.text("menu.pause_60"), #selector(pause60))
            add(sub, L10n.text("menu.pause_today"), #selector(pauseToday))
            add(sub, L10n.text("menu.pause_indefinite"), #selector(pauseIndefinite))
            item.submenu = sub
        }
        if model.settings.timingModel == .rounds {
            add(menu, L10n.text("plan.restart_round"), #selector(restartRound))
            add(menu, L10n.text("plan.restart_group"), #selector(restartGroup))
        }
        menu.addItem(.separator())
        add(menu, L10n.text("menu.settings"), #selector(openSettings), key: ",")
            .image = NSImage(systemSymbolName: SettingsPage.general.symbol, accessibilityDescription: nil)
        add(menu, L10n.text("menu.about"), #selector(openAbout)).image = NSImage(systemSymbolName: SettingsPage.about.symbol, accessibilityDescription: nil)
        menu.addItem(.separator())
        add(menu, L10n.text("menu.quit"), #selector(quit), key: "q")
            .image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
    }
    func menuDidClose(_ menu: NSMenu) {
        menuStateItem = nil; menuPlan = nil; menuRoundItem = nil
        menuCountdownItems.removeAll()
    }
    @discardableResult private func add(_ menu: NSMenu, _ title: String, _ action: Selector?, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self; item.isEnabled = action != nil; menu.addItem(item); return item
    }
    @objc private func restartRound() { model.action { $0.restartFocus(group: false, now: Date()) } }
    @objc private func restartGroup() { model.action { $0.restartFocus(group: true, now: Date()) } }
    @objc private func startCurrentBreak() { model.action { $0.startNow($0.roundRestKind ?? .short, now: Date()) } }
    @objc private func startShort() { model.action { $0.startNow(.short, now: Date()) } }
    @objc private func startLong() { model.action { $0.startNow(.long, now: Date()) } }
    @objc private func endRest() { model.action { $0.finish(now: Date()) } }
    @objc private func previewRest() { windows.preview() }
    @objc private func resume() { model.resume() }
    @objc private func pause15() { model.pauseMinutes(15) }
    @objc private func pause60() { model.pauseMinutes(60) }
    @objc private func pauseToday() { model.pauseToday() }
    @objc private func pauseIndefinite() { model.action { $0.setPause(.indefinite, now: Date()) } }
    @objc private func openAbout() { settingsNavigation.page = .about; openSettings() }
    @objc func openSettings() {
        if settingsWindow == nil {
            settingsWindow = makeWindow(title: settingsNavigation.page.title, size: NSSize(width: 860, height: 640), content: SettingsView(model: model, navigation: settingsNavigation), managesToolbar: true)
            settingsWindow?.minSize = NSSize(width: 720, height: 540)
            settingsWindow?.styleMask.insert(.fullSizeContentView)
            // A hosting controller lets NavigationSplitView install its native toolbar.
            settingsWindow?.contentViewController = NSHostingController(
                rootView: SettingsView(model: model, navigation: settingsNavigation)
            )
        }
        model.refreshLogin(); model.refreshNotificationStatus(); show(settingsWindow!)
        DispatchQueue.main.async { [weak self] in self?.configureSettingsToolbar() }
    }
    private func configureSettingsToolbar() {
        guard let window = settingsWindow,
              let split = findSplitViewController(in: window.contentView) else { return }
        settingsSplitController = split
        split.splitViewItems.first?.allowsFullHeightLayout = true
        guard window.toolbar?.identifier != NSToolbar.Identifier(AppIdentity.identifier("settingsToolbar")) else { return }
        settingsTitleField.stringValue = settingsNavigation.page.title
        settingsTitleField.font = .systemFont(ofSize: 13, weight: .semibold)
        settingsTitleField.setContentCompressionResistancePriority(.required, for: .horizontal)
        window.titleVisibility = .hidden
        let toolbar = NSToolbar(identifier: NSToolbar.Identifier(AppIdentity.identifier("settingsToolbar")))
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.showsBaselineSeparator = false
        window.toolbarStyle = .unified
        (window as? SettingsWindow)?.managedToolbar = toolbar
        window.toolbar = toolbar
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, sidebarToolbarIdentifier, separatorToolbarIdentifier, titleToolbarIdentifier, .flexibleSpace]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if identifier == separatorToolbarIdentifier, let split = settingsSplitController?.splitView {
            return NSTrackingSeparatorToolbarItem(identifier: identifier, splitView: split, dividerIndex: 0)
        }
        let item = NSToolbarItem(itemIdentifier: identifier)
        if identifier == sidebarToolbarIdentifier {
            item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: nil)
            item.target = self
            item.action = #selector(toggleSettingsSidebar)
            let label = sidebarToolbarLabel(settingsNavigation.columnVisibility)
            item.label = label
            item.toolTip = label
            return item
        }
        if identifier == titleToolbarIdentifier {
            item.view = settingsTitleField
            return item
        }
        return nil
    }
    private func sidebarToolbarLabel(_ visibility: NavigationSplitViewVisibility) -> String {
        L10n.text(visibility == .detailOnly ? "settings.sidebar.show" : "settings.sidebar.hide")
    }
    private func updateSidebarToolbarLabel(_ visibility: NavigationSplitViewVisibility) {
        let item = settingsWindow?.toolbar?.items.first { $0.itemIdentifier == sidebarToolbarIdentifier }
        item?.label = sidebarToolbarLabel(visibility)
        item?.toolTip = sidebarToolbarLabel(visibility)
    }
    @objc private func toggleSettingsSidebar() {
        let visibility: NavigationSplitViewVisibility = settingsNavigation.columnVisibility == .detailOnly ? .all : .detailOnly
        let animation: Animation? = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeInOut(duration: 0.25)
        withAnimation(animation) { settingsNavigation.columnVisibility = visibility }
    }

    private func findSplitViewController(in view: NSView?) -> NSSplitViewController? {
        guard let view else { return nil }
        if view is NSSplitView {
            var responder: NSResponder? = view.nextResponder
            while let current = responder {
                if let controller = current as? NSSplitViewController { return controller }
                responder = current.nextResponder
            }
        }
        for child in view.subviews {
            if let controller = findSplitViewController(in: child) { return controller }
        }
        return nil
    }
    private func openWelcome() {
        welcomeWindow = makeWindow(title: L10n.text("welcome.title"), size: NSSize(width: 580, height: 1), content: WelcomeView(model: model, finish: { [weak self] in
            self?.model.update { $0.onboardingComplete = true }
            self?.welcomeWindow?.close(); self?.openSettings()
        }, layoutChanged: { [weak self] in self?.resizeWelcome() }))
        welcomeWindow?.styleMask.remove(.resizable)
        resizeWelcome()
        welcomeWindow?.center()
        show(welcomeWindow!)
    }
    private func resizeWelcome() {
        guard let window = welcomeWindow, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let oldTop = window.frame.maxY
        window.setContentSize(NSSize(width: 580, height: ceil(content.fittingSize.height)))
        var frame = window.frame
        frame.origin.y = oldTop - frame.height
        window.setFrame(frame, display: true)
    }
    private func makeWindow<V: View>(title: String, size: NSSize, content: V, managesToolbar: Bool = false) -> NSWindow {
        let windowType: NSWindow.Type = managesToolbar ? SettingsWindow.self : NSWindow.self
        let window = windowType.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title; window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.contentView = NSHostingView(rootView: content.environment(\.locale, L10n.locale))
        window.center(); return window
    }
    private func show(_ window: NSWindow) { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
    @objc private func quit() {
        if model.engine.isResting {
            let alert = NSAlert(); alert.messageText = L10n.text("quit.title"); alert.informativeText = L10n.text("quit.body")
            alert.addButton(withTitle: L10n.text("menu.quit")); alert.addButton(withTitle: L10n.text("common.cancel"))
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() != .alertFirstButtonReturn { return }
        }
        NSApp.terminate(nil)
    }
}

/// Keep one native toolbar owner when SwiftUI updates the split view's columns.
private final class SettingsWindow: NSWindow {
    var managedToolbar: NSToolbar?
    override var toolbar: NSToolbar? {
        get { super.toolbar }
        set { super.toolbar = managedToolbar ?? newValue }
    }
    override var titleVisibility: NSWindow.TitleVisibility {
        get { super.titleVisibility }
        set { super.titleVisibility = managedToolbar == nil ? newValue : .hidden }
    }
}
