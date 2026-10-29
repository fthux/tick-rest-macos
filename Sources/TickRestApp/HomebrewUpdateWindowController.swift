import AppKit
import Combine
import SwiftUI
import TickRestCore

/// One independent window for user-initiated checks; background checks stay silent.
@MainActor final class HomebrewUpdateWindowController: NSObject, NSWindowDelegate {
    private weak var updates: HomebrewUpdateController?
    private var subscription: AnyCancellable?
    private var renderedStatus: HomebrewUpdateController.Status?
    private var renderedLanguage: String?
    private(set) var window: NSWindow?
    private(set) var alert: NSAlert?
    private let openURL: (URL) -> Void

    init(updates: HomebrewUpdateController, openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.updates = updates
        self.openURL = openURL
        super.init()
        subscription = updates.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        guard let updates, updates.showsUpdateWindow else { close(); return }
        if window == nil || renderedStatus != updates.status || renderedLanguage != L10n.language {
            close()
            switch updates.status {
            case .idle, .checking: makeProgressWindow()
            case .available, .incompatible: makePromptWindow(updates)
            case .upToDate, .failed: makeResultAlert(updates)
            }
            renderedStatus = updates.status
            renderedLanguage = L10n.language
            window?.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.delegate = nil
        window?.close()
        window = nil
        alert = nil
        renderedStatus = nil
    }

    func windowWillClose(_ notification: Notification) {
        updates?.dismissUpdateWindow()
    }

    private func makeProgressWindow() {
        let panel = UpdateCheckPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 164),
                                     styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.title = L10n.text("update.window_title")
        let root = NSView()
        panel.contentView = root
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        let heading = NSTextField(wrappingLabelWithString: L10n.text("update.checking"))
        heading.font = .boldSystemFont(ofSize: 15)
        let progress = NSProgressIndicator()
        progress.style = .bar
        progress.isIndeterminate = true
        progress.setAccessibilityLabel(L10n.text("update.checking"))
        let cancel = NSButton(title: L10n.text("common.cancel"), target: self, action: #selector(dismiss))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let buttonRow = NSStackView(views: [NSView(), cancel])
        buttonRow.orientation = .horizontal
        let content = NSStackView(views: [heading, progress, buttonRow])
        content.translatesAutoresizingMaskIntoConstraints = false
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 18
        root.addSubview(icon)
        root.addSubview(content)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            icon.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            icon.widthAnchor.constraint(equalToConstant: 64), icon.heightAnchor.constraint(equalToConstant: 64),
            content.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            content.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -20),
            heading.widthAnchor.constraint(equalTo: content.widthAnchor),
            progress.widthAnchor.constraint(equalTo: content.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: content.widthAnchor),
            cancel.widthAnchor.constraint(greaterThanOrEqualToConstant: 100)
        ])
        progress.startAnimation(nil)
        panel.delegate = self
        window = panel
    }

    private func makeResultAlert(_ updates: HomebrewUpdateController) {
        let result = NSAlert()
        result.icon = NSApp.applicationIconImage
        switch updates.status {
        case .upToDate:
            result.messageText = L10n.text("update.latest_title")
            result.informativeText = L10n.text("update.latest_body", updates.currentVersion)
            result.addButton(withTitle: L10n.text("update.ok"))
            result.buttons[0].target = self
            result.buttons[0].action = #selector(dismiss)
        default:
            result.alertStyle = .warning
            result.messageText = L10n.text("update.failed_title")
            result.informativeText = updates.statusText
            result.addButton(withTitle: L10n.text("update.retry"))
            result.buttons[0].target = self
            result.buttons[0].action = #selector(retry)
            result.addButton(withTitle: L10n.text("common.close"))
            result.buttons[1].target = self
            result.buttons[1].action = #selector(dismiss)
            result.buttons[1].keyEquivalent = "\u{1b}"
        }
        let history = result.addButton(withTitle: L10n.text("update.history"))
        history.target = self
        history.action = #selector(openHistory)
        result.layout()
        result.window.isReleasedWhenClosed = false
        result.window.delegate = self
        alert = result
        window = result.window
    }

    private func makePromptWindow(_ updates: HomebrewUpdateController) {
        let content = NSHostingView(rootView: HomebrewUpdatePrompt(
            updates: updates
        ).environment(\.locale, L10n.locale))
        let size = HomebrewUpdatePrompt.contentSize
        let panel = UpdateCheckPanel(contentRect: NSRect(origin: .zero, size: size),
                                     styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        panel.title = L10n.text("update.prompt_window_title")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        content.frame = NSRect(origin: .zero, size: size)
        panel.contentView = content
        panel.delegate = self
        window = panel
    }

    @objc private func dismiss() {
        updates?.dismissUpdateWindow()
        close()
    }
    @objc private func retry() { updates?.checkInteractively() }
    @objc private func openHistory() {
        if let updates { openURL(updates.releaseHistoryURL) }
    }
}

private final class UpdateCheckPanel: NSPanel {
    override func cancelOperation(_ sender: Any?) { close() }
}
