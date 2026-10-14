import AppKit
import SwiftUI
import TickRestCore

enum AboutLinks {
    static let author = "fthux"
    static let email = "penleymcleod@gmail.com"
    static let website = URL(string: "https://tick-rest.fthux.com")!
    static let source = URL(string: "https://github.com/fthux/tick-rest-macos")!
    static let issues = source.appendingPathComponent("issues")
    static let mail = URL(string: "mailto:\(email)")!
}

enum AboutCopyright {
    static func text(on date: Date = Date()) -> String {
        let year = Calendar(identifier: .gregorian).component(.year, from: date)
        return "© \(year) \(AboutLinks.author). All rights reserved."
    }
}

struct AboutView: View {
    let buildInfo: AppBuildInfo
    @Binding var country: AboutCountry?
    var errorMessage: String?
    var dismissError: () -> Void = {}
    @State private var copyrightDate = Date()

    // The About page and the .icns are exported from the same icon artwork.
    private static let icon = L10n.resourceBundle.url(forResource: "AppIcon", withExtension: "png")
        .flatMap(NSImage.init(contentsOf:))

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if let errorMessage {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        Text(errorMessage).font(.callout)
                        Spacer()
                        Button(action: dismissError) { Image(systemName: "xmark") }
                            .accessibilityLabel(L10n.text("common.dismiss"))
                    }
                }
                header
                applicationSection
                openSourceSection
                feedbackSection
                sharingSection
                creditsSection
                Text(AboutCopyright.text(on: copyrightDate))
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.top, 4)
            }
            .frame(maxWidth: 900)
            .padding(.horizontal, 28).padding(.top, 32).padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(.orange)
        .task {
            guard country == nil else { return }
            let result = await AboutCountry.lookup()
            guard !Task.isCancelled else { return }
            country = result
        }
        .onAppear { copyrightDate = Date() }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            copyrightDate = Date()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            copyrightDate = Date()
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            if let icon = Self.icon {
                Image(nsImage: icon).resizable().interpolation(.high)
                    .frame(width: 70.4, height: 70.4).accessibilityHidden(true)
            }
            Text(L10n.text("app.name")).font(.system(size: 28, weight: .bold)).padding(.top, 4)
            Text(buildInfo.shortVersionDescription).font(.callout).foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text(L10n.text("about.description")).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 580)
        }
        .frame(maxWidth: .infinity).padding(.bottom, 8)
    }

    private var applicationSection: some View {
        AboutSection(title: "about.group.application") {
            AboutCard {
                AboutRow(title: "about.package") {
                    Text(buildInfo.packageDescription).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let country {
                    Divider().padding(.horizontal, 18)
                    AboutRow(title: "about.availability", description: country.availabilityText) {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.orange)
                            .accessibilityHidden(true)
                    }
                }
            }
            Text(L10n.text("about.health")).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
        }
    }

    private var openSourceSection: some View {
        AboutSection(title: "about.group.open_source") {
            AboutCard {
                AboutRow(title: "about.source", description: L10n.text("about.source_description")) {
                    Link(L10n.text("about.view_github"), destination: AboutLinks.source)
                        .buttonStyle(.plain).foregroundStyle(.orange)
                }
            }
            Text(starInvitation).font(.caption).foregroundStyle(.secondary).tint(.orange)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
        }
    }

    private var starInvitation: AttributedString {
        var text = AttributedString(L10n.text("about.star_message"))
        if let star = text.range(of: "Star") {
            text[star].link = AboutLinks.source
            text[star].foregroundColor = .orange
        }
        return text
    }

    private var feedbackSection: some View {
        AboutSection(title: "about.group.feedback") {
            AboutCard {
                AboutRow(title: "about.website", description: AboutLinks.website.absoluteString) {
                    Link(L10n.text("about.open_website"), destination: AboutLinks.website)
                        .buttonStyle(.plain).foregroundStyle(.orange)
                }
                Divider().padding(.horizontal, 18)
                AboutRow(title: "about.report_bug", description: L10n.text("about.feedback_description")) {
                    Link(L10n.text("about.open_issue"), destination: AboutLinks.issues)
                        .buttonStyle(.plain).foregroundStyle(.orange)
                }
                Divider().padding(.horizontal, 18)
                AboutRow(title: "about.email", description: AboutLinks.email) {
                    HStack(spacing: 8) {
                        CopyFeedbackButton(title: "about.copy_email", value: AboutLinks.email)
                        Link(L10n.text("about.send_email"), destination: AboutLinks.mail)
                    }
                }
            }
        }
    }

    private var sharingSection: some View {
        AboutSection(title: "about.group.sharing") {
            AboutCard {
                AboutRow(title: "about.share_app", description: L10n.text("about.share_description"),
                         stacksActionsWhenNeeded: false) {
                    AboutShareMenu()
                }
            }
        }
    }

    private var creditsSection: some View {
        AboutSection(title: "about.group.credits") {
            AboutCard {
                AboutRow(title: "about.created_by") {
                    Text(AboutLinks.author).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
    }
}

private struct AboutSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text(title)).font(.headline).foregroundStyle(.secondary)
                .padding(.horizontal, 4).accessibilityAddTraits(.isHeader)
            content
        }
    }
}

private struct AboutCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: SettingsPalette.aboutCard), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct AboutRow<Actions: View>: View {
    let title: String
    var description: String? = nil
    var stacksActionsWhenNeeded = true
    @ViewBuilder var actions: Actions
    var body: some View {
        rowContent
            .padding(.horizontal, 18).padding(.vertical, 16)
    }
    @ViewBuilder private var rowContent: some View {
        if stacksActionsWhenNeeded {
            // Stack the actions below the label when translations exceed the available width.
            ViewThatFits(in: .horizontal) {
                horizontalContent
                VStack(alignment: .leading, spacing: 12) {
                    label
                    actions
                }
            }
        } else {
            horizontalContent
        }
    }
    private var horizontalContent: some View {
        HStack(spacing: 20) {
            label
            Spacer(minLength: 12)
            actions.fixedSize(horizontal: true, vertical: false)
        }
    }
    private var label: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.text(title)).font(.body)
            if let description {
                Text(description).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
    }
}

private struct AboutShareMenu: View {
    @State private var copied = false
    @State private var showsQRCode = false

    var body: some View {
        Menu {
            ShareLink(item: AboutLinks.website,
                      subject: Text(L10n.text("about.share_app")),
                      message: Text(L10n.text("about.share_message"))) {
                Label(L10n.text("about.share"), systemImage: "square.and.arrow.up")
            }
            Button {
                NSPasteboard.general.clearContents()
                copied = NSPasteboard.general.setString(AboutLinks.website.absoluteString, forType: .string)
            } label: {
                Label(L10n.text(copied ? "about.copied" : "about.copy_link"),
                      systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            Button { showsQRCode = true } label: {
                Label(L10n.text("about.qr_code"), systemImage: "qrcode")
            }
        } label: {
            Label(L10n.text("about.share"), systemImage: "square.and.arrow.up")
        }
        .popover(isPresented: $showsQRCode, arrowEdge: .bottom) { AboutQRCodeView() }
        .task(id: copied) {
            guard copied else { return }
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            copied = false
        }
    }
}

private struct CopyFeedbackButton: View {
    let title: String
    let value: String
    @State private var copied = false
    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            copied = NSPasteboard.general.setString(value, forType: .string)
        } label: {
            Label(L10n.text(copied ? "about.copied" : title),
                  systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .help(value)
        .task(id: copied) {
            guard copied else { return }
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            copied = false
        }
    }
}
