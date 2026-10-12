import AppKit
import Combine
import QuartzCore
import SwiftUI
import TickRestCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSToolbarDelegate {
    private var status: NSStatusItem!
    private var model: AppController!
    private var windows: WindowCoordinator!
    private var statusSubscription: AnyCancellable?
    private let statusDotRenderer = StatusDotRenderer()
    private var menuPlan: RestPlan?
    private var menuLanguage: String?
    private var menuKinds: [BreakKind] = []
    private var menuResting = false
    private var menuHasReminder = false
    private var menuRoundItem: NSMenuItem?
    private var menuSkipItem: NSMenuItem?
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
    private let injectedStore: DataStore?
    private let injectedLockDirectory: URL?

    // Tests run the real launch/menu/window paths with an isolated store and lock.
    // The default app entry point retains its normal per-user locations.
    init(store: DataStore? = nil, lockDirectory: URL? = nil) {
        injectedStore = store; injectedLockDirectory = lockDirectory
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A per-user flock avoids duplicate schedulers without a persistent stale PID file.
        let lockDirectory = injectedLockDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent(AppIdentity.dataDirectory)
        try? FileManager.default.createDirectory(at: lockDirectory, withIntermediateDirectories: true)
        lockFD = open(lockDirectory.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            DistributedNotificationCenter.default().postNotificationName(NSNotification.Name(AppIdentity.identifier("showSettings")), object: nil)
            NSApp.terminate(nil); return
        }
        model = injectedStore.map { AppController(store: $0) } ?? AppController(); windows = WindowCoordinator(model: model)
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
        NotificationCenter.default.addObserver(self, selector: #selector(previewRest(_:)), name: .previewRest, object: nil)
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
        let display = ReminderDisplay(engine: engine)
        let symbol = display.statusSymbolName
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: L10n.text("app.name"))
        let title = display.menuBarText
        button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        button.attributedTitle = statusDotRenderer.title(
            text: model.settings.showCountdown ? title : "",
            color: model.settings.showStatusDot ? model.settings.statusDotPalette[display.statusDotState] : nil,
            font: button.font!
        )
        button.toolTip = L10n.text("app.name") + " — " + model.stateText
        button.setAccessibilityLabel(button.toolTip)
        if menuStateItem != nil, let menu = status.menu,
           menuPlan != model.settings.restPlan || menuKinds != engine.displayKinds
           || menuResting != engine.isResting || menuHasReminder != (engine.reminder != nil)
           || menuLanguage != L10n.language { menuWillOpen(menu) }
        menuRoundItem?.title = display.roundRestText
        menuSkipItem?.toolTip = display.skipResultText
        menuStateItem?.title = display.menuStateText
        updateMenuStatusVisibility(display)
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
        menuLanguage = L10n.language
        menuKinds = model.engine.displayKinds; menuResting = model.engine.isResting
        menuHasReminder = model.engine.reminder != nil
        menuCountdownItems.removeAll()
        let display = ReminderDisplay(engine: model.engine)
        menuStateItem = add(menu, display.menuStateText, nil)
        menuRoundItem = model.settings.timingModel == .rounds && model.engine.roundRestKind != nil
            ? add(menu, display.roundRestText, nil) : nil
        updateMenuStatusVisibility(display)
        if !model.engine.isResting {
            for kind in model.engine.displayKinds {
                menuCountdownItems[kind] = add(menu, display.countdownText(for: kind), nil)
            }
        }
        menu.addItem(.separator())
        if !model.engine.isResting {
            if model.settings.timingModel == .dual {
                if model.settings.shortEnabled { add(menu, L10n.text("menu.start_short"), #selector(startShort)) }
                if model.settings.longEnabled { add(menu, L10n.text("menu.start_long"), #selector(startLong)) }
            } else { add(menu, L10n.text("plan.start_now"), #selector(startCurrentBreak)) }
        }
        menuSkipItem = model.engine.reminder != nil ? add(menu, L10n.text("rest.skip"), #selector(skipRest)) : nil
        menuSkipItem?.toolTip = display.skipResultText
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
    private func updateMenuStatusVisibility(_ display: ReminderDisplay) {
        // The focus countdown already includes the round; keep separate exceptional states visible.
        menuStateItem?.isHidden = model.settings.timingModel == .rounds
            && model.engine.roundRestKind == nil && display.statusDotState == .working
        if let item = menuRoundItem { item.isHidden = item.title == display.menuStateText }
    }
    func menuDidClose(_ menu: NSMenu) {
        menuStateItem = nil; menuPlan = nil; menuLanguage = nil; menuRoundItem = nil; menuSkipItem = nil
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
    @objc private func skipRest() { model.action { $0.skip(now: Date()) } }
    @objc private func previewRest(_ notification: Notification) {
        let id = notification.userInfo?["screenID"] as? String
        windows.preview(screen: id.flatMap { id in NSScreen.screens.first { ConnectedDisplay.identifier(for: $0) == id } })
    }
    @objc private func resume() { model.resume() }
    @objc private func pause15() { model.pauseMinutes(15) }
    @objc private func pause60() { model.pauseMinutes(60) }
    @objc private func pauseToday() { model.pauseToday() }
    @objc private func pauseIndefinite() { model.action { $0.setPause(.indefinite, now: Date()) } }
    @objc private func openAbout() { settingsNavigation.page = .about; openSettings() }
    @objc func openSettings() {
        if settingsWindow == nil {
            settingsWindow = makeWindow(title: settingsNavigation.page.title, size: NSSize(width: 920, height: 680), content: SettingsView(model: model, navigation: settingsNavigation), managesToolbar: true)
            settingsWindow?.styleMask.insert(.fullSizeContentView)
            // A hosting controller lets NavigationSplitView install its native toolbar.
            settingsWindow?.contentViewController = NSHostingController(
                rootView: SettingsView(model: model, navigation: settingsNavigation)
            )
            // Hosting installs its own sizing constraints; apply ours afterward.
            settingsWindow?.minSize = NSSize(width: 780, height: 580)
        }
        model.refreshLogin(); model.refreshNotificationStatus(); show(settingsWindow!)
        DispatchQueue.main.async { [weak self] in self?.configureSettingsToolbar() }
    }
    private func configureSettingsToolbar() {
        guard let window = settingsWindow,
              let split = findSplitViewController(in: window.contentView) else { return }
        settingsSplitController = split
        split.splitViewItems.first?.allowsFullHeightLayout = true
        // Keep sidebar changes inside the window instead of preserving detail width.
        split.splitViewItems.first?.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        // Use the titlebar background and safe area as the visual boundary.
        for item in split.splitViewItems.dropFirst() {
            item.titlebarSeparatorStyle = .none
        }
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
        window.titlebarAppearsTransparent = false
        window.titlebarSeparatorStyle = .none
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // Keep the control against the sidebar's right edge, inside its divider.
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
            item.visibilityPriority = .high
            item.target = self
            item.action = #selector(toggleSettingsSidebar)
            let label = sidebarToolbarLabel(settingsNavigation.columnVisibility)
            item.label = label
            item.toolTip = label
            // Native image items reserve too much width beside the traffic lights.
            let button = NSButton(image: NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: nil)!,
                                  target: self, action: #selector(toggleSettingsSidebar))
            button.isBordered = false
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = label
            button.setAccessibilityLabel(label)
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 24),
                button.heightAnchor.constraint(equalToConstant: 24)
            ])
            item.view = button
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
        item?.view?.toolTip = sidebarToolbarLabel(visibility)
        item?.view?.setAccessibilityLabel(sidebarToolbarLabel(visibility))
    }
    @objc private func toggleSettingsSidebar() {
        guard let sidebar = settingsSplitController?.splitViewItems.first else { return }
        let visibility: NavigationSplitViewVisibility = settingsNavigation.columnVisibility == .detailOnly ? .all : .detailOnly
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // Animate the native split once. A SwiftUI animation on columnVisibility
        // also animates the hosted List/Form layout while AppKit resizes its panes.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = reduceMotion ? 0 : 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                if reduceMotion { sidebar.isCollapsed = visibility == .detailOnly }
                else { sidebar.animator().isCollapsed = visibility == .detailOnly }
            }
            settingsNavigation.columnVisibility = visibility
        }
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
            self?.welcomeWindow?.close()
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
    override var titlebarAppearsTransparent: Bool {
        get { super.titlebarAppearsTransparent }
        set { super.titlebarAppearsTransparent = managedToolbar == nil ? newValue : false }
    }
}
