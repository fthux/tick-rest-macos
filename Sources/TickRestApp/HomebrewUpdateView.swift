import AppKit
import SwiftUI
import TickRestCore

extension Notification.Name {
    static let quitForHomebrewUpdate = Notification.Name(AppIdentity.identifier("quitForHomebrewUpdate"))
}

struct HomebrewUpdateSection: View {
    @ObservedObject var updates: HomebrewUpdateController

    var body: some View {
        SettingsFormSection(title: L10n.text("update.title"),
                            footer: Text(L10n.text("update.auto_help")), spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    status
                    Spacer(minLength: 12)
                    checkButton
                }
                VStack(alignment: .leading, spacing: 12) { status; checkButton }
            }
            if let checked = updates.lastChecked {
                Text(L10n.text("update.last_checked", checked.formatted(date: .abbreviated, time: .shortened)))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let update = updates.availableUpdate {
                Button(L10n.text("update.menu_available", update.version)) { updates.showAvailableUpdate() }
            }
            Link(L10n.text("update.history"), destination: updates.releaseHistoryURL)
            Divider()
            Toggle(L10n.text("update.automatic"), isOn: Binding(
                get: { updates.automaticChecks }, set: { updates.setAutomaticChecks($0) }
            ))
            .toggleStyle(.switch).controlSize(.small)
        }
    }

    private var status: some View {
        HStack(spacing: 8) {
            if updates.isChecking { ProgressView().controlSize(.small) }
            Text(updates.statusText).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }.accessibilityElement(children: .combine)
    }

    private var checkButton: some View {
        Button(L10n.text("update.check")) { updates.checkInteractively() }.fixedSize()
    }
}

struct HomebrewUpdateInstructions: View {
    @ObservedObject var updates: HomebrewUpdateController
    @State private var copied = false
    @State private var copyFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("update.found")).font(.title3.bold())
                    Text(L10n.text("update.current", updates.currentVersion)).foregroundStyle(.secondary)
                }
            }
            if let update = updates.availableUpdate {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text("update.available", update.version)).font(.headline)
                    if !update.summary.isEmpty {
                        ViewThatFits(in: .vertical) {
                            summary(update.summary).fixedSize(horizontal: false, vertical: true)
                            ScrollView { summary(update.summary) }
                        }
                        .frame(maxHeight: 140)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Link(L10n.text("update.release_notes"), destination: update.historyDetailsURL)
                        .buttonStyle(.link)
                }
                if updates.canUpgrade {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.text("update.instructions")).font(.headline)
                        Text(L10n.text("update.steps")).fixedSize(horizontal: false, vertical: true)
                        Text(HomebrewUpdateConfiguration.upgradeCommand)
                            .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        if copyFailed { Text(L10n.text("update.copy_failed")).foregroundStyle(.red) }
                    }
                } else {
                    Text(L10n.text("update.requires_system", update.version, update.minimumSystemVersion))
                        .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                HStack(spacing: 12) {
                    Link(L10n.text("update.history"), destination: updates.releaseHistoryURL)
                    if updates.canUpgrade {
                        Button(L10n.text(copied ? "update.copied" : "update.copy")) { copyCommand() }
                        Button(L10n.text("update.copy_quit")) {
                            guard copyCommand() else { return }
                            NotificationCenter.default.post(name: .quitForHomebrewUpdate, object: nil)
                        }
                    }
                }
                .fixedSize(horizontal: true, vertical: true)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(20).frame(width: 560)
        .buttonStyle(.bordered).tint(.orange)
        .task(id: copied) {
            guard copied else { return }
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            copied = false
        }
    }

    private func summary(_ text: String) -> some View {
        Text(text).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
    }

    @discardableResult private func copyCommand() -> Bool {
        NSPasteboard.general.clearContents()
        copied = NSPasteboard.general.setString(HomebrewUpdateConfiguration.upgradeCommand, forType: .string)
        copyFailed = !copied
        return copied
    }
}
