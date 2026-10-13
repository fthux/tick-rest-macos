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

private struct WeekdayToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            configuration.label
                .foregroundStyle(configuration.isOn ? Color.white : Color.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(configuration.isOn ? Color.orange : Color.primary.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
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
    @Published var detailScrolled = false
    @Published var overviewSelection = StatisticsSelection()
}

struct SettingsView: View {
    @ObservedObject var model: AppController
    @ObservedObject var navigation: SettingsNavigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var buildInfo = AppBuildInfo.current
    private var page: SettingsPage { navigation.page }
    @State private var confirmClear = false
    @State private var recordsCleared = false
    @State private var aboutCountry: AboutCountry?
    @State private var connectedDisplays = ConnectedDisplay.current
    @State private var displayIdentification = DisplayIdentificationController()
    var body: some View {
        GeometryReader { viewport in
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
                            .padding(.horizontal, 10)
                        )
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .background { SettingsSidebarBackground().ignoresSafeArea() }
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
                GeometryReader { detailViewport in
                    // A non-scrolling container keeps the Form's viewport inside the
                    // detail safe area, including during scroll rubber-banding.
                    ZStack(alignment: .top) {
                        settingsContent(for: page)
                            // A new page gets its own scroll viewport. Passing the page
                            // explicitly also keeps outgoing content stable as it fades.
                            .id(page)
                            .transition(pageTransition)
                    }
                    .frame(width: detailViewport.size.width, height: detailViewport.size.height, alignment: .topLeading)
                    // Animate only page changes, leaving the sidebar and toolbar immediate.
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: page)
                    .overlay(alignment: .top) {
                        if navigation.detailScrolled {
                            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 0.5)
                                .allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
                    .clipped()
                    .background(Color(nsColor: SettingsPalette.content), ignoresSafeAreaEdges: .top)
                    .background(SettingsScrollObserver { navigation.detailScrolled = $0 })
                }
            }
            // Constrain the whole split view so AppKit does not add the sidebar width
            // to a minimum that was imposed on the window while the sidebar was hidden.
            // Anchor the leading edge while AppKit reconciles the split width during
            // a reveal; centering temporarily wider content moves the menu text left.
            .frame(width: viewport.size.width, height: viewport.size.height, alignment: .topLeading)
        }
        .frame(minWidth: SettingsWindowLayout.minimumContentSize.width,
               minHeight: SettingsWindowLayout.minimumContentSize.height, alignment: .topLeading)
        .toggleStyle(SettingsSwitchToggleStyle())
        .environment(\.locale, model.interfaceLocale)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            displayIdentification.clear()
            connectedDisplays = ConnectedDisplay.current
        }
        .onChange(of: page) { _ in
            displayIdentification.clear()
            navigation.detailScrolled = false
        }
        .onChange(of: model.settings.selectedDisplayID) { _ in displayIdentification.clear() }
        .onDisappear { displayIdentification.clear() }
        .confirmationDialog(L10n.text("data.clear_title"), isPresented: $confirmClear) {
            Button(L10n.text("data.clear"), role: .destructive) { recordsCleared = model.clearRecords() }
            Button(L10n.text("common.cancel"), role: .cancel) {}
        } message: { Text(L10n.text("data.clear_body")) }
    }
    private var pageTransition: AnyTransition {
        reduceMotion ? .identity : .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 8)),
            removal: .opacity
        )
    }
    @ViewBuilder private func settingsContent(for page: SettingsPage) -> some View {
        if page == .appearance {
            if model.settings.style == .overlay {
                fullscreenAppearance
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 20) {
                        reminderStyleCard
                        appearanceError
                        appearance
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 32)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else { settingsForm(for: page) }
    }
    private var reminderStyleCard: some View {
        SettingsSectionCard {
            HStack {
                Text(L10n.text("reminder.style"))
                Spacer(minLength: 20)
                Picker(L10n.text("reminder.style"), selection: binding(\.style)) {
                    ForEach(ReminderStyle.allCases, id: \.self) {
                        Text(L10n.text("style.\($0.rawValue)")).tag($0)
                    }
                }
                .pickerStyle(.menu).labelsHidden().fixedSize().buttonStyle(.borderless)
            }.frame(maxWidth: .infinity)
            Text(L10n.text("reminder.style_help")).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    private var fullscreenAppearance: some View {
        BackgroundSettingsView(model: model, styleSelection: { reminderStyleCard }) {
            appearanceError
            appearance
        }.id(model.interfaceLanguage)
    }
    @ViewBuilder private var appearanceError: some View {
        if let error = model.errorMessage {
            HStack(alignment: .top) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(error).font(.callout)
                Spacer()
                Button { model.dismissError() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel(L10n.text("common.dismiss"))
            }
        }
    }
    private func settingsForm(for page: SettingsPage) -> some View {
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
    private var appearance: some View {
        Group {
            appearanceCard { appearanceControls }
            appearanceCard {
                appearanceSoundControls
                Divider()
                Text(L10n.text("plan.actions_help")).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func appearanceCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        SettingsSectionCard(content: content)
            .buttonStyle(.bordered)
            .pickerStyle(.menu)
    }
    private func appearanceRow<Content: View>(_ title: String, _ description: String? = nil,
                                             @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.text(title))
                if let description {
                    Text(L10n.text(description)).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            content().fixedSize()
        }.frame(maxWidth: .infinity)
    }
    private var appearanceControls: some View {
        Group {
            if model.settings.style == .gentle {
                appearanceRow("reminder.size", "reminder.size_help") {
                    Picker(L10n.text("reminder.size"), selection: binding(\.gentleReminderSize)) {
                        ForEach(GentleReminderSize.allCases, id: \.self) {
                            Text(L10n.text("reminder.size.\($0.rawValue)")).tag($0)
                        }
                    }.labelsHidden().buttonStyle(.borderless)
                }
                Divider()
                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L10n.text("reminder.position"))
                        Text(model.settings.gentleReminderPosition.title)
                            .font(.caption).foregroundStyle(.secondary)
                        Text(L10n.text("reminder.position_help"))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    gentlePositionPicker.fixedSize()
                        .help(L10n.text("reminder.position_help"))
                }.frame(maxWidth: .infinity)
                Divider()
            }
            appearanceRow("reminder.start_mode", "reminder.start_mode_help") {
                Picker(L10n.text("reminder.start_mode"), selection: binding(\.breakStartMode)) {
                    ForEach(BreakStartMode.allCases, id: \.self) { Text(L10n.text("start_mode.\($0.rawValue)")).tag($0) }
                }.labelsHidden().buttonStyle(.borderless)
            }
            if model.settings.style == .gentle {
                Divider()
                Button(L10n.text("reminder.preview")) { NotificationCenter.default.post(name: .previewRest, object: nil) }.disabled(model.engine.reminder != nil)
            }
        }
    }
    private var appearanceSoundControls: some View {
        Group {
            appearanceRow("reminder.prewarning") {
                Picker(L10n.text("reminder.prewarning"), selection: binding(\.prewarning)) {
                    Text(L10n.text("common.off")).tag(0.0)
                    ForEach([10, 30, 60], id: \.self) { Text(L10n.text("duration.seconds", $0)).tag(Double($0)) }
                }.labelsHidden().buttonStyle(.borderless)
            }
            Divider()
            appearanceRow("reminder.sound", "reminder.sound_help") { toggle("reminder.sound", \.sound) }
            Divider()
            appearanceRow("reminder.sound_type") {
                Picker(L10n.text("reminder.sound_type"), selection: binding(\.reminderSound)) {
                    ForEach(ReminderSound.allCases, id: \.self) { sound in
                        Text(sound.title).tag(sound)
                    }
                }.labelsHidden().buttonStyle(.borderless)
            }
            Divider()
            Button(L10n.text("reminder.test_sound")) { model.playReminderSound() }
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
                        .toggleStyle(WeekdayToggleStyle())
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
            ScheduleClockTime.date(minutes: model.settings[keyPath: path])
        }, set: { date in
            let minutes = Calendar.current.component(.hour, from: date) * 60 + Calendar.current.component(.minute, from: date)
            model.update { $0[keyPath: path] = minutes }
        })
    }
    private var displays: some View {
        Group {
            Section {
                row("displays.scope") {
                    Picker(L10n.text("displays.scope"), selection: Binding(get: { model.settings.displayScope }, set: { scope in
                        model.update {
                            $0.displayScope = scope
                            if scope == .selected, $0.selectedDisplayID == nil {
                                $0.selectedDisplayID = connectedDisplays.first?.id
                            }
                        }
                    })) {
                        ForEach(DisplayScope.allCases, id: \.self) { Text(L10n.text("display.\($0.rawValue)")).tag($0) }
                    }.labelsHidden()
                }
                if model.settings.displayScope == .selected {
                    row("displays.selected") {
                        HStack {
                            Picker(L10n.text("displays.selected"), selection: binding(\.selectedDisplayID)) {
                                if model.settings.selectedDisplayID == nil {
                                    Text(L10n.text("displays.choose")).tag(nil as String?)
                                } else if !connectedDisplays.contains(where: { $0.id == model.settings.selectedDisplayID }) {
                                    Text(L10n.text("displays.disconnected")).tag(model.settings.selectedDisplayID)
                                }
                                ForEach(connectedDisplays) { display in
                                    Text(display.name).tag(Optional(display.id))
                                }
                            }.labelsHidden()
                            Button(L10n.text("displays.identify")) {
                                displayIdentification.identify(model.settings.selectedDisplayID)
                            }
                            .disabled(!connectedDisplays.contains { $0.id == model.settings.selectedDisplayID })
                            .help(L10n.text("displays.identify_help"))
                        }
                    }
                    Text(L10n.text("displays.selected_help")).font(.caption).foregroundStyle(.secondary)
                }
                Text(L10n.text("displays.help")).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text(L10n.text("displays.connected", connectedDisplays.count)).font(.callout)
                ForEach(connectedDisplays) { display in
                    HStack {
                        Label(display.name, systemImage: "display").font(.callout)
                        Spacer()
                        Button(L10n.text("displays.identify")) { displayIdentification.identify(display.id) }
                            .help(L10n.text("displays.identify_help"))
                    }
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
                Button(role: .destructive) { recordsCleared = false; confirmClear = true } label: {
                    Text(L10n.text("data.clear")).foregroundStyle(.red)
                }
                if recordsCleared {
                    Label(L10n.text("data.clear_success"), systemImage: "checkmark.circle.fill")
                        .font(.callout).foregroundStyle(.green)
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
                        Text(buildInfo.versionDescription)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                Text(L10n.text("about.description")).font(.callout)
                if let aboutCountry {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.orange)
                        Text(aboutCountry.availabilityText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.callout.weight(.medium))
                    .padding(.vertical, 4)
                }
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

/// Shared grouping for settings rendered outside the native grouped Form.
struct SettingsSectionCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: SettingsPalette.card), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
    }
}

extension Notification.Name { static let previewRest = Notification.Name(AppIdentity.identifier("previewRest")) }
