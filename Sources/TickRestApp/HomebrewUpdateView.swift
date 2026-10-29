import AppKit
import SwiftUI
import TickRestCore

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
            if updates.installer.isActive {
                HStack {
                    Button(L10n.text("update.show_progress")) { updates.installer.showProgress() }
                    Spacer()
                    if updates.installer.canCancel {
                        Button(L10n.text("common.cancel")) { updates.installer.cancel() }
                    }
                }
            } else if updates.availableUpdate != nil {
                HStack {
                    Button(L10n.text("update.view_update")) { updates.showAvailableUpdate() }
                    Spacer()
                    Button(L10n.text("update.install")) { updates.installUpdate() }
                        .disabled(!updates.canUpgrade || updates.installer.isActive)
                        .tint(Color(nsColor: .systemBlue))
                }
            }
            if let error = updates.installer.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Link(L10n.text("update.history"), destination: updates.releaseHistoryURL)
            Divider()
            Toggle(L10n.text("update.automatic_install"), isOn: Binding(
                get: { updates.automaticInstallation }, set: { updates.setAutomaticInstallation($0) }
            ))
            .toggleStyle(.switch).controlSize(.small)
        }
    }

    private var status: some View {
        HStack(spacing: 8) {
            if updates.isChecking || updates.installer.isActive { ProgressView().controlSize(.small) }
            Text(updates.statusText).fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(updates.status == .incompatible ? Color.red : Color.primary)
                .textSelection(.enabled)
        }.accessibilityElement(children: .combine)
    }

    private var checkButton: some View {
        Button(L10n.text("update.check")) { updates.checkInteractively() }.fixedSize()
            .disabled(updates.installer.isActive)
    }
}

/// Compact native update prompt. Installation continues in the independent helper.
struct HomebrewUpdatePrompt: View {
    static let contentSize = NSSize(width: 620, height: 370)
    private static let icon = L10n.resourceBundle.url(forResource: "AppIcon", withExtension: "png")
        .flatMap(NSImage.init(contentsOf:))

    @ObservedObject var updates: HomebrewUpdateController

    private var releaseNotes: [String] {
        guard let summary = updates.availableUpdate?.summary else { return [] }
        return summary.split(whereSeparator: \.isNewline).compactMap { line in
            var text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let prefix = ["• ", "- ", "* "].first(where: { text.hasPrefix($0) }) {
                text.removeFirst(prefix.count)
                text = text.trimmingCharacters(in: .whitespaces)
            }
            return text.isEmpty ? nil : text
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            Image(nsImage: Self.icon ?? NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 52, height: 52)
                .padding(.top, 18)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.text("update.prompt_heading"))
                    .font(.system(size: 16, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                if updates.availableUpdate != nil {
                    Text(L10n.text("update.prompt_body", updates.availableVersionText, updates.currentVersionText))
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(L10n.text("update.release_notes_heading"))
                    .font(.system(size: 13, weight: .semibold))

                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        if releaseNotes.isEmpty {
                            Text(L10n.text("update.no_release_notes"))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if let update = updates.availableUpdate {
                                Link(L10n.text("update.release_notes"), destination: update.releaseNotesURL)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        } else {
                            ForEach(Array(releaseNotes.enumerated()), id: \.offset) { _, note in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text("•")
                                    Text(note).fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .textSelection(.enabled)
                    .font(.system(size: 14))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(Rectangle().stroke(Color(nsColor: .separatorColor), lineWidth: 1))
                .accessibilityLabel(L10n.text("update.release_notes_heading"))

                if let error = updates.installer.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let update = updates.availableUpdate, !updates.canUpgrade {
                    Text(L10n.text("update.requires_system", update.version, update.minimumSystemVersion))
                        .font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle(L10n.text("update.automatic_install"), isOn: Binding(
                    get: { updates.automaticInstallation }, set: { updates.setAutomaticInstallation($0) }
                ))
                .toggleStyle(.checkbox).font(.system(size: 13))
                HStack(spacing: 10) {
                    Button(L10n.text("update.skip_version")) { updates.skipVersion() }
                    Spacer(minLength: 8)
                    Button(L10n.text("update.remind_later")) { updates.remindLater() }
                    Button(L10n.text("update.install")) { updates.installUpdate() }
                        .disabled(!updates.canUpgrade || updates.installer.isActive)
                        .buttonStyle(.borderedProminent)
                        .tint(Color(nsColor: .systemBlue))
                        .keyboardShortcut(.defaultAction)
                }
                .controlSize(.regular)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
        .frame(width: Self.contentSize.width, height: Self.contentSize.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .buttonStyle(.bordered)
    }
}
