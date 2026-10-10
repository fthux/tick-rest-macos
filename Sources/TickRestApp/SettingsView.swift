import SwiftUI
import AppKit
import TickRestCore

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, rhythm, appearance, schedule, displays, today, privacy, about
    var id: String { rawValue }
    var title: String { L10n.text("settings.\(rawValue)") }
    var symbol: String {
        switch self {
        case .today: return "chart.bar"
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
}

struct SettingsView: View {
    @ObservedObject var model: AppController
    @ObservedObject var navigation: SettingsNavigation
    private var page: SettingsPage { navigation.page }
    @State private var confirmClear = false
    var body: some View {
        NavigationSplitView(columnVisibility: $navigation.columnVisibility) {
            List(selection: Binding<SettingsPage?>(
                get: { navigation.page },
                set: { if let page = $0 { navigation.page = page } }
            )) {
                ForEach(SettingsPage.allCases) { item in
                    Label(item.title, systemImage: item.symbol).tag(item)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 206, max: 260)
        } detail: {
            Form {
                if let error = model.errorMessage {
                    Section {
                        HStack(alignment: .top) {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                            Text(error).font(.callout)
                            Spacer()
                            Button { model.errorMessage = nil } label: { Image(systemName: "xmark") }
                                .buttonStyle(.plain).accessibilityLabel(L10n.text("common.dismiss"))
                        }
                    }
                }
                switch page {
                case .today: Section { TodayView(model: model) }
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
        }
        .toggleStyle(.switch)
        .environment(\.locale, L10n.locale)
        .confirmationDialog(L10n.text("data.clear_title"), isPresented: $confirmClear) {
            Button(L10n.text("data.clear"), role: .destructive) { model.clearRecords() }
            Button(L10n.text("common.cancel"), role: .cancel) {}
        } message: { Text(L10n.text("data.clear_body")) }
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
            Section {
                row("general.countdown", "general.countdown_help") { toggle("general.countdown", \.showCountdown) }
                row("general.theme") {
                    Picker(L10n.text("general.theme"), selection: binding(\.theme)) {
                        ForEach(AppTheme.allCases, id: \.self) { Text(L10n.text("theme.\($0.rawValue)")).tag($0) }
                    }.labelsHidden()
                }
                row("general.language", "general.language_help") {
                    Picker(L10n.text("general.language"), selection: binding(\.language)) {
                        Text(L10n.text("language.system")).tag("system")
                        ForEach(L10n.availableLanguages, id: \.self) { language in
                            Text(L10n.locale.localizedString(forIdentifier: language) ?? language).tag(language)
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
            Text(model.stateText).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var rhythm: some View {
        Group {
            Text(L10n.text("rhythm.help")).font(.callout).foregroundStyle(.secondary)
            Section {
                row("break.short", "rhythm.short_help") { toggle("break.short", \.shortEnabled) }
                Stepper(value: minutes(\.shortInterval), in: 1...120, step: 1) { Text(L10n.text("rhythm.interval_minutes", Int(model.settings.shortInterval / 60))) }
                    .controlSize(.small)
                    .disabled(!model.settings.shortEnabled)
                Stepper(value: binding(\.shortDuration), in: 10...300, step: 5) { Text(L10n.text("rhythm.duration_seconds", Int(model.settings.shortDuration))) }
                    .controlSize(.small)
                    .disabled(!model.settings.shortEnabled)
            }
            Section {
                row("break.long", "rhythm.long_help") { toggle("break.long", \.longEnabled) }
                Stepper(value: minutes(\.longInterval), in: 1...240, step: 1) { Text(L10n.text("rhythm.interval_minutes", Int(model.settings.longInterval / 60))) }
                    .controlSize(.small)
                    .disabled(!model.settings.longEnabled)
                Text(L10n.text("rhythm.interval_rule"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Stepper(value: minutes(\.longDuration), in: 1...30, step: 1) { Text(L10n.text("rhythm.duration_minutes", Int(model.settings.longDuration / 60))) }
                    .controlSize(.small)
                    .disabled(!model.settings.longEnabled)
            }
            Text(L10n.text("rhythm.merge_help")).font(.caption).foregroundStyle(.secondary)
        }
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
                Button(L10n.text("reminder.test_sound")) { NSSound(named: "Glass")?.play() }
            }
            Text(L10n.text("reminder.defer_help")).font(.caption).foregroundStyle(.secondary)
        }
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
            Section {
                Text(model.stateText).font(.callout)
                HStack {
                    Button(L10n.text("menu.pause_15")) { model.pauseMinutes(15) }
                    Button(L10n.text("menu.resume")) { model.resume() }.disabled(model.engine.pause == nil)
                }
                Text(L10n.text("schedule.meeting_help")).font(.caption).foregroundStyle(.secondary)
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
                Button(L10n.text("data.clear"), role: .destructive) { confirmClear = true }
            }
        }
    }
    private var about: some View {
        Section {
            HStack(spacing: 16) {
                Image(systemName: "leaf.fill").font(.system(size: 36)).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.text("app.name")).font(.title2.bold())
                    Text(L10n.text("about.version", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(L10n.text("about.description")).font(.callout)
            Text(L10n.text("about.development")).font(.caption).foregroundStyle(.secondary)
            Text(L10n.text("about.health")).font(.caption).foregroundStyle(.secondary)
            Text(L10n.text("about.languages")).font(.caption).foregroundStyle(.secondary)
        }
    }
}

extension Notification.Name { static let previewRest = Notification.Name(AppIdentity.identifier("previewRest")) }
