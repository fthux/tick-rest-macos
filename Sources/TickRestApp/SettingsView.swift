import SwiftUI
import AppKit
import TickRestCore

private struct SettingsSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration)
            .toggleStyle(.switch)
            .tint(.orange)
            .accentColor(.orange)
    }
}

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, rhythm, schedule, appearance, displays, overview, privacy, about
    var id: String { rawValue }
    var title: String { L10n.text("settings.\(rawValue)") }
    var symbol: String {
        switch self {
        case .overview: return "chart.bar"
        case .general: return "gearshape"
        case .rhythm: return "timer"
        case .appearance: return "paintpalette"
        case .schedule: return "moon.zzz"
        case .displays: return "display"
        case .privacy: return "hand.raised"
        case .about: return "info.circle"
        }
    }
}

final class SettingsNavigation: ObservableObject {
    @Published var columnVisibility: NavigationSplitViewVisibility = .all
    @Published var page: SettingsPage = .general
    @Published var overviewSelection = StatisticsSelection()
}

struct SettingsView: View {
    @ObservedObject var model: AppController
    @ObservedObject var navigation: SettingsNavigation
    private var page: SettingsPage { navigation.page }
    @State private var confirmClear = false
    @State private var aboutCountry: AboutCountry?
    var body: some View {
        NavigationSplitView(columnVisibility: $navigation.columnVisibility) {
            // Draw the selected background ourselves: native sidebar selection
            // can keep the system accent color despite tint/accentColor overrides.
            List {
                ForEach(SettingsPage.allCases) { item in
                    Button { navigation.page = item } label: {
                        Label(item.title, systemImage: item.symbol)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(page == item ? .isSelected : [])
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(page == item ? Color.orange : Color.clear)
                    )
                }
            }
            .listStyle(.sidebar)
            .onMoveCommand { direction in
                guard let index = SettingsPage.allCases.firstIndex(of: page) else { return }
                let next: Int
                switch direction {
                case .up: next = max(0, index - 1)
                case .down: next = min(SettingsPage.allCases.count - 1, index + 1)
                default: return
                }
                navigation.page = SettingsPage.allCases[next]
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 206, max: 260)
            // Native List rows can retain labels when their stable IDs do not change.
            .id(model.interfaceLanguage)
        } detail: {
            // A non-scrolling container keeps the Form's viewport inside the
            // detail safe area, including during scroll rubber-banding.
            VStack(spacing: 0) {
                settingsForm
                    .padding(.top, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .background(Color(nsColor: .windowBackgroundColor), ignoresSafeAreaEdges: [])
        }
        .toggleStyle(SettingsSwitchToggleStyle())
        .environment(\.locale, model.interfaceLocale)
        .confirmationDialog(L10n.text("data.clear_title"), isPresented: $confirmClear) {
            Button(L10n.text("data.clear"), role: .destructive) { model.clearRecords() }
            Button(L10n.text("common.cancel"), role: .cancel) {}
        } message: { Text(L10n.text("data.clear_body")) }
    }
    private var settingsForm: some View {
        Form {
            if let error = model.errorMessage {
                Section {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        Text(error).font(.callout)
                        Spacer()
                        Button { model.dismissError() } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).accessibilityLabel(L10n.text("common.dismiss"))
                    }
                }
            }
            switch page {
            case .overview: Section { OverviewView(model: model, navigation: navigation) }
            case .general: general
            case .rhythm: rhythm
            case .appearance: appearance
            case .schedule: schedule
            case .displays: displays
            case .privacy: privacy
            case .about: about
            }
        }
        .formStyle(.grouped)
        .buttonStyle(.bordered)
        .scrollContentBackground(.hidden)
        // Recreate cached Picker options as well as the visible form labels.
        .id(model.interfaceLanguage)
    }
    private func binding<T>(_ path: WritableKeyPath<TickRestCore.Settings, T>) -> Binding<T> {
        Binding(get: { model.settings[keyPath: path] }, set: { value in model.update { $0[keyPath: path] = value } })
    }
    private func minutes(_ path: WritableKeyPath<TickRestCore.Settings, Double>) -> Binding<Double> {
        Binding(get: { model.settings[keyPath: path] / 60 }, set: { value in model.update { $0[keyPath: path] = value * 60 } })
    }
    private func row(_ title: String, _ description: String? = nil, @ViewBuilder content: () -> some View) -> some View {
        LabeledContent {
            content()
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.text(title))
                if let description { Text(L10n.text(description)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
        }
    }
    private func toggle(_ key: String, _ path: WritableKeyPath<TickRestCore.Settings, Bool>) -> some View {
        Toggle(L10n.text(key), isOn: binding(path))
            .labelsHidden().fixedSize()
            .accessibilityLabel(L10n.text(key))
    }
    private var general: some View {
        Group {
            Section {
                row("general.login", "general.login_help") {
                    Toggle(L10n.text("general.login"), isOn: Binding(get: { model.launchAtLogin }, set: model.setLogin))
                        .labelsHidden().fixedSize()
                }
            }
            Section(L10n.text("general.menu_bar")) {
                row("general.countdown", "general.countdown_help") { toggle("general.countdown", \.showCountdown) }
                row("general.status_dot", "general.status_dot_help") { toggle("general.status_dot", \.showStatusDot) }
                Group {
                    Text(L10n.text("general.status_dot_colors")).font(.caption).foregroundStyle(.secondary)
                    ForEach(StatusDotState.allCases, id: \.self) { state in
                        LabeledContent(state.title) {
                            AnchoredColorPicker(selection: statusDotColor(state), label: state.title)
                                .frame(width: 44, height: 22)
                        }
                    }
                    Button(L10n.text("general.status_dot_reset")) {
                        model.update { $0.statusDotPalette = StatusDotPalette() }
                    }
                }.disabled(!model.settings.showStatusDot)
            }
            Section {
                row("general.theme") {
                    Picker(L10n.text("general.theme"), selection: binding(\.theme)) {
                        ForEach(AppTheme.allCases, id: \.self) { Text(L10n.text("theme.\($0.rawValue)")).tag($0) }
                    }.labelsHidden()
                }
                row("general.language", "general.language_help") {
                    Picker(L10n.text("general.language"), selection: Binding(
                        get: { model.settings.language == "system" ? "system" : L10n.resolvedLanguage },
                        set: { language in model.update { $0.language = language } }
                    )) {
                        Text(L10n.text("language.system")).tag("system")
                        ForEach(L10n.availableLanguages, id: \.self) { language in
                            Text(L10n.languageDisplayName(language)).tag(language)
                        }
                    }.labelsHidden()
                }
            }
            Section {
                row("general.notifications", "general.notifications_help") {
                    Text(L10n.text(model.notificationStatus)).foregroundStyle(.secondary)
                }
                Button(L10n.text("general.request_notifications")) { model.requestNotifications() }
            }
        }
    }
    private func statusDotColor(_ state: StatusDotState) -> Binding<Color> {
        Binding(get: {
            let color = model.settings.statusDotPalette[state]
            return Color(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: 1)
        }, set: { value in
            guard let color = NSColor(value).usingColorSpace(.sRGB) else { return }
            model.update {
                $0.statusDotPalette[state] = StatusDotColor(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent)
            }
        })
    }
    private var rhythm: some View { PlanEditor(model: model) }
    private var overlayBackgroundColor: Binding<Color> {
        Binding(get: {
            let color = model.settings.overlayBackgroundColor
            return Color(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: 1)
        }, set: { value in
            guard let color = NSColor(value).usingColorSpace(.sRGB) else { return }
            model.update {
                $0.overlayBackgroundColor = SRGBColor(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent)
            }
        })
    }
    private var appearance: some View {
        Group {
            Section {
                row("reminder.style") {
                    Picker(L10n.text("reminder.style"), selection: binding(\.style)) {
                        ForEach(ReminderStyle.allCases, id: \.self) { Text(L10n.text("style.\($0.rawValue)")).tag($0) }
                    }.labelsHidden()
                }
                Text(L10n.text("reminder.style_help")).font(.caption).foregroundStyle(.secondary)
                if model.settings.style == .gentle {
                    row("reminder.size", "reminder.size_help") {
                        Picker(L10n.text("reminder.size"), selection: binding(\.gentleReminderSize)) {
                            ForEach(GentleReminderSize.allCases, id: \.self) {
                                Text(L10n.text("reminder.size.\($0.rawValue)")).tag($0)
                            }
                        }.labelsHidden()
                    }
                    LabeledContent {
                        gentlePositionPicker
                            .help(L10n.text("reminder.position_help"))
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(L10n.text("reminder.position"))
                            Text(model.settings.gentleReminderPosition.title)
                                .font(.caption).foregroundStyle(.secondary)
                            Text(L10n.text("reminder.position_help"))
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else {
                    row("reminder.background_color", "reminder.background_color_help") {
                        AnchoredColorPicker(selection: overlayBackgroundColor, label: L10n.text("reminder.background_color"))
                            .frame(width: 44, height: 22)
                    }
                    Button(L10n.text("reminder.background_color_reset")) {
                        model.update { $0.overlayBackgroundColor = TickRestCore.Settings.defaultOverlayBackgroundColor }
                    }
                }
                row("reminder.start_mode", "reminder.start_mode_help") {
                    Picker(L10n.text("reminder.start_mode"), selection: binding(\.breakStartMode)) {
                        ForEach(BreakStartMode.allCases, id: \.self) { Text(L10n.text("start_mode.\($0.rawValue)")).tag($0) }
                    }.labelsHidden()
                }
                Button(L10n.text("reminder.preview")) { NotificationCenter.default.post(name: .previewRest, object: nil) }.disabled(model.engine.reminder != nil)
            }
            Section {
                row("reminder.prewarning") {
                    Picker(L10n.text("reminder.prewarning"), selection: binding(\.prewarning)) {
                        Text(L10n.text("common.off")).tag(0.0)
                        ForEach([10, 30, 60], id: \.self) { Text(L10n.text("duration.seconds", $0)).tag(Double($0)) }
                    }.labelsHidden()
                }
                row("reminder.sound", "reminder.sound_help") { toggle("reminder.sound", \.sound) }
                row("reminder.sound_type") {
                    Picker(L10n.text("reminder.sound_type"), selection: binding(\.reminderSound)) {
                        ForEach(ReminderSound.allCases, id: \.self) { sound in
                            Text(sound.title).tag(sound)
                        }
                    }.labelsHidden()
                }
                Button(L10n.text("reminder.test_sound")) { model.playReminderSound() }
            }
            Text(L10n.text("plan.actions_help")).font(.caption).foregroundStyle(.secondary)
        }
    }
    private var gentlePositionPicker: some View {
        GentlePositionPicker(selection: binding(\.gentleReminderPosition))
    }
    private var schedule: some View {
        Group {
            Section {
                row("schedule.enabled", "schedule.help") { toggle("schedule.enabled", \.scheduleEnabled) }
                HStack(spacing: 5) {
                    ForEach(1...7, id: \.self) { day in
                        Toggle(weekday(day), isOn: Binding(
                            get: { model.settings.weekdays.contains(day) },
                            set: { selected in
                                model.update {
                                    if selected { $0.weekdays.insert(day) }
                                    else { $0.weekdays.remove(day) }
                                }
                            }
                        ))
                        .toggleStyle(.button)
                        .frame(maxWidth: .infinity)
                    }
                }.disabled(!model.settings.scheduleEnabled)
                HStack {
                    DatePicker(L10n.text("schedule.start"), selection: timeBinding(\.scheduleStart), displayedComponents: .hourAndMinute)
                    DatePicker(L10n.text("schedule.end"), selection: timeBinding(\.scheduleEnd), displayedComponents: .hourAndMinute)
                }.disabled(!model.settings.scheduleEnabled)
                Text(L10n.text("schedule.overnight")).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                row("schedule.idle", "schedule.idle_help") { toggle("schedule.idle", \.detectIdle) }
                Stepper(value: minutes(\.idleTimeout), in: 1...60, step: 1) {
                    Text(L10n.text("schedule.idle_minutes", Int(model.settings.idleTimeout / 60)))
                }
                .controlSize(.small)
                .disabled(!model.settings.detectIdle)
                row("schedule.fullscreen", "schedule.fullscreen_help") { toggle("schedule.fullscreen", \.avoidFullscreen) }
                if model.fullscreenUnavailable { Text(L10n.text("schedule.fullscreen_unavailable")).font(.caption).foregroundStyle(.orange) }
            }
        }
    }
    private func weekday(_ index: Int) -> String {
        let formatter = DateFormatter(); formatter.locale = L10n.locale
        return formatter.shortWeekdaySymbols[index - 1]
    }
    private func timeBinding(_ path: WritableKeyPath<TickRestCore.Settings, Int>) -> Binding<Date> {
        Binding(get: {
            Calendar.current.date(byAdding: .minute, value: model.settings[keyPath: path], to: Calendar.current.startOfDay(for: Date()))!
        }, set: { date in
            let minutes = Calendar.current.component(.hour, from: date) * 60 + Calendar.current.component(.minute, from: date)
            model.update { $0[keyPath: path] = minutes }
        })
    }
    private var displays: some View {
        Group {
            Section {
                row("displays.scope") {
                    Picker(L10n.text("displays.scope"), selection: binding(\.displayScope)) {
                        ForEach(DisplayScope.allCases, id: \.self) { Text(L10n.text("display.\($0.rawValue)")).tag($0) }
                    }.labelsHidden()
                }
                Text(L10n.text("displays.help")).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text(L10n.text("displays.connected", NSScreen.screens.count)).font(.callout)
                ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { _, screen in
                    Label(screen.localizedName, systemImage: "display").font(.callout)
                }
            }
            Text(L10n.text("displays.limitations")).font(.caption).foregroundStyle(.secondary)
        }
    }
    private var privacy: some View {
        Group {
            Section {
                Label(L10n.text("data.local"), systemImage: "lock.shield").font(.headline)
                Text(L10n.text("data.help")).font(.callout).foregroundStyle(.secondary)
                Text(L10n.text("data.retention")).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text(L10n.text("data.directory")).font(.callout)
                Text(model.store.url.deletingLastPathComponent().path).font(.caption.monospaced()).textSelection(.enabled).foregroundStyle(.secondary)
                Button(L10n.text("data.open_directory")) { NSWorkspace.shared.open(model.store.url.deletingLastPathComponent()) }
                Button(role: .destructive) { confirmClear = true } label: {
                    Text(L10n.text("data.clear")).foregroundStyle(.red)
                }
            }
        }
    }
    private var about: some View {
        Group {
            Section {
                HStack(spacing: 16) {
                    Image(systemName: "leaf.fill").font(.system(size: 36)).foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L10n.text("app.name")).font(.title2.bold())
                        Text(L10n.text("about.version", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(L10n.text("about.description")).font(.callout)
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.orange)
                    Text(aboutCountry?.availabilityText ?? L10n.text("about.free"))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout.weight(.medium))
                .padding(.vertical, 4)
                Text(L10n.text("about.health")).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                SettingsExternalLink(title: L10n.text("about.source"), systemImage: "chevron.left.forwardslash.chevron.right",
                                     destination: URL(string: "https://github.com/fthux/tick-rest-macos")!)
                SettingsExternalLink(title: L10n.text("about.website"), systemImage: "globe",
                                     destination: URL(string: "https://tick-rest.fthux.com")!)
                SettingsExternalLink(title: L10n.text("about.email"), systemImage: "envelope",
                                     destination: URL(string: "mailto:penleymcleod@gmail.com")!)
                SettingsExternalLink(title: L10n.text("about.report_bug"), systemImage: "ladybug",
                                     destination: URL(string: "https://github.com/fthux/tick-rest-macos/issues")!)
            }
        }
        .task {
            guard aboutCountry == nil else { return }
            let country = await AboutCountry.lookup()
            guard !Task.isCancelled else { return }
            aboutCountry = country
        }
    }
}

/// External destinations share a quiet appearance and keep native Link behavior.
struct SettingsExternalLink: View {
    let title: String
    var systemImage: String? = nil
    let destination: URL
    @State private var isHovered = false
    @FocusState private var isFocused: Bool
    private var iconColor: Color { isHovered || isFocused ? .orange : .secondary }

    var body: some View {
        Link(destination: destination) {
            HStack(spacing: 10) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .frame(width: 20)
                        .foregroundStyle(iconColor)
                        .accessibilityHidden(true)
                }
                Text(title).foregroundStyle(.primary)
                Spacer(minLength: 12)
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(iconColor)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovered || isFocused ? Color.orange.opacity(0.08) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isFocused ? Color.orange : .clear, lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tint(.orange)
        .focused($isFocused)
        .onHover { isHovered = $0 }
        .help(destination.absoluteString)
    }
}

extension Notification.Name { static let previewRest = Notification.Name(AppIdentity.identifier("previewRest")) }
