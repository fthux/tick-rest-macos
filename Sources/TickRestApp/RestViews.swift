import SwiftUI
import TickRestCore

private let restColor = Color(red: 0.12, green: 0.28, blue: 0.21)

struct GentleCardLayout {
    let size: GentleReminderSize
    var width: CGFloat { size == .normal ? 420 : size == .small ? 340 : 280 }
    var padding: CGFloat { size == .normal ? 24 : size == .small ? 18 : 14 }
    var spacing: CGFloat { size == .normal ? 15 : size == .small ? 10 : 8 }
    var clockFont: CGFloat { size == .normal ? 52 : size == .small ? 40 : 24 }
    var radius: CGFloat { size == .normal ? 18 : size == .small ? 16 : 14 }
    var compact: Bool { size != .normal }
}

// Nonactivating panels need explicit colors for every action, independent of window focus.
private struct RestCardButtonStyle: ButtonStyle {
    var prominent = false
    var compact = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font((compact ? Font.callout : Font.body).weight(.medium))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, compact ? 10 : 16)
            .padding(.vertical, compact ? 6 : 8)
            .background(prominent ? restColor : Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.5)
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct RestPostponeButton: View {
    @ObservedObject var model: AppController
    let reminder: Reminder
    private var isDisabled: Bool { reminder.postponements >= model.settings.postponeLimit }
    private var disabledReason: String {
        L10n.text(model.settings.postponeLimit == 0 ? "rest.defer_disabled" : "rest.defer_limit")
    }

    var body: some View {
        VStack(spacing: 4) {
            Button(L10n.text("rest.defer", Int(model.settings.postponement(reminder.kind) / 60))) {
                model.action { $0.postpone(now: Date()) }
            }
            .disabled(isDisabled)
            .help(isDisabled ? disabledReason : "")
            if isDisabled {
                Text(disabledReason).font(.caption)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct RestCard: View {
    @ObservedObject var model: AppController
    let size: GentleReminderSize
    let preview: Bool
    let previewEnd: () -> Void
    @State private var showingIdea = false
    private var layout: GentleCardLayout { GentleCardLayout(size: size) }
    private var r: Reminder { model.engine.reminder ?? model.settings.previewReminder }
    var body: some View {
        VStack(spacing: layout.spacing) {
            HStack(spacing: 8) {
                Label(r.title, systemImage: r.kind == .short ? "eye" : "figure.walk")
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if size == .mini { clock }
                Button { close() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel(L10n.text("common.close"))
            }.font((size == .mini ? Font.caption : Font.callout).bold())
            if !preview, model.settings.timingModel == .rounds {
                Text(L10n.text("plan.focus_state", model.engine.focusRound, model.settings.rounds))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if size != .mini { clock }
            HStack(spacing: 8) {
                Text(L10n.text(preview ? "rest.preview" : model.engine.isResting ? "rest.running" : "rest.waiting"))
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(size == .mini ? .leading : .center)
                    .fixedSize(horizontal: false, vertical: true)
                if size == .mini {
                    Spacer(minLength: 0)
                    Button { showingIdea.toggle() } label: { Image(systemName: "info.circle") }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.text("rest.idea"))
                        .help(L10n.text("rest.idea"))
                        .popover(isPresented: $showingIdea) {
                            Text(r.idea).font(.callout).padding(16).frame(width: 260)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                }
            }
            if size != .mini {
                Text(r.idea)
                    .font(.callout).multilineTextAlignment(.center).frame(maxWidth: .infinity).fixedSize(horizontal: false, vertical: true)
            }
            ViewThatFits(in: .horizontal) {
                HStack { primaryAction; secondaryActions }
                VStack(spacing: 8) {
                    primaryAction
                    ViewThatFits(in: .horizontal) {
                        HStack { secondaryActions }
                        VStack(spacing: 8) { secondaryActions }
                    }
                }
            }.buttonStyle(RestCardButtonStyle(compact: layout.compact))
        }.padding(layout.padding).frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: layout.radius))
            .overlay(RoundedRectangle(cornerRadius: layout.radius).stroke(.secondary.opacity(0.2)))
            .padding(1).tint(restColor)
            .environment(\.locale, L10n.locale)
    }
    private var clock: some View {
        Text(preview ? "00:05" : L10n.clock(r.target - r.elapsed))
            .font(.system(size: layout.clockFont, weight: .regular, design: .rounded)).monospacedDigit()
            .fixedSize()
            .accessibilityLabel(L10n.text("rest.remaining", L10n.duration(preview ? 5 : r.target - r.elapsed)))
    }
    @ViewBuilder private var primaryAction: some View {
        if preview {
            Button(L10n.text("common.close"), action: previewEnd)
        } else {
            Button(L10n.text(model.engine.isResting ? "rest.end" : "rest.start")) {
                model.action { if $0.isResting { $0.finish(now: Date()) } else { $0.start(now: Date()) } }
            }.buttonStyle(RestCardButtonStyle(prominent: true, compact: layout.compact))
        }
    }
    @ViewBuilder private var secondaryActions: some View {
        if !preview {
            RestPostponeButton(model: model, reminder: r)
            Button(L10n.text("rest.skip")) { model.action { $0.skip(now: Date()) } }
        }
    }
    private func close() {
        if preview { previewEnd() }
        else { model.action { if $0.isResting { $0.finish(now: Date()) } else { $0.skip(now: Date()) } } }
    }
}

struct OverlayPalette {
    let background: SRGBColor
    private let lightText = SRGBColor(red: 0.91, green: 0.95, blue: 0.84)
    private func luminance(_ color: SRGBColor) -> Double {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }
    var usesDarkText: Bool {
        let brightness = luminance(background)
        return (brightness + 0.05) / 0.05 >= (luminance(lightText) + 0.05) / (brightness + 0.05)
    }
    var foreground: Color {
        usesDarkText ? .black : Color(.sRGB, red: lightText.red, green: lightText.green, blue: lightText.blue)
    }
    var backgroundColor: Color {
        Color(.sRGB, red: background.red, green: background.green, blue: background.blue)
    }
    var colorScheme: ColorScheme { usesDarkText ? .light : .dark }
}

struct OverlayView: View {
    @ObservedObject var model: AppController
    let preview: Bool
    let primary: Bool
    let previewEnd: () -> Void
    private var r: Reminder { model.engine.reminder ?? model.settings.previewReminder }
    private var palette: OverlayPalette { OverlayPalette(background: model.settings.overlayBackgroundColor) }
    var body: some View {
        VStack(spacing: 25) {
            if primary { Image(systemName: r.kind == .short ? "leaf" : "figure.walk").font(.system(size: 40)).accessibilityHidden(true) }
            Text(r.title).font(.title2)
            if !preview, model.settings.timingModel == .rounds {
                Text(L10n.text("plan.focus_state", model.engine.focusRound, model.settings.rounds)).font(.callout)
            }
            Text(preview ? "00:05" : L10n.clock(r.target - r.elapsed)).font(.system(size: primary ? 88 : 52, weight: .light, design: .rounded)).monospacedDigit()
            if primary {
                if !preview {
                    Text(L10n.text(model.engine.isResting ? "rest.running" : "rest.waiting"))
                        .font(.caption)
                }
                Text(preview ? L10n.text("rest.preview") : r.idea)
                    .font(.title3).multilineTextAlignment(.center).frame(maxWidth: 600)
                HStack(spacing: 16) {
                    if preview { Button(L10n.text("common.close"), action: previewEnd) }
                    else {
                        if !model.engine.isResting {
                            Button(L10n.text("rest.start")) { model.action { $0.start(now: Date()) } }
                        }
                        RestPostponeButton(model: model, reminder: r)
                        if model.engine.isResting {
                            Button(L10n.text("rest.end")) { model.action { $0.finish(now: Date()) } }
                        }
                        Button(L10n.text("rest.skip")) { model.action { $0.skip(now: Date()) } }
                    }
                }.buttonStyle(.bordered).controlSize(.large)
            }
        }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(palette.foreground)
            .background(palette.backgroundColor)
            .preferredColorScheme(palette.colorScheme)
            .environment(\.locale, L10n.locale)
    }
}

struct WarningView: View {
    @ObservedObject var model: AppController
    let kind: BreakKind
    private var settings: TickRestCore.Settings { model.settings }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "leaf").font(.title2).foregroundStyle(restColor)
            VStack(alignment: .leading, spacing: 7) {
                Text(L10n.text("app.name")).font(.callout.bold())
                Text(L10n.text("warning.body", Int(settings.prewarning), settings.breakTitle(kind), L10n.duration(settings.duration(kind)))).font(.callout)
            }
            Spacer(minLength: 0)
        }.padding(17).frame(maxWidth: .infinity, maxHeight: .infinity).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)).padding(1)
            .environment(\.locale, L10n.locale)
    }
}

struct OverviewView: View {
    @ObservedObject var model: AppController
    @ObservedObject var navigation: SettingsNavigation
    var body: some View {
        let now = Date()
        let range = navigation.overviewSelection.range(now: now)
        let available = StatisticsDateRange.availableDates(now: now)
        let summary = model.summary(in: range)
        VStack(alignment: .leading, spacing: 20) {
            Picker(L10n.text("overview.period"), selection: Binding(
                get: { navigation.overviewSelection.preset },
                set: { navigation.overviewSelection.select($0) }
            )) {
                ForEach(StatisticsPreset.allCases) { preset in
                    Text(L10n.text("overview.period.\(preset.rawValue)")).tag(preset)
                }
            }.pickerStyle(.menu).frame(maxWidth: .infinity)
            if navigation.overviewSelection.preset == .custom {
                VStack(alignment: .leading, spacing: 12) {
                    DatePicker(L10n.text("overview.start_date"), selection: Binding(
                        get: { navigation.overviewSelection.range().start },
                        set: { navigation.overviewSelection.setCustomStart($0) }
                    ), in: available, displayedComponents: .date)
                    DatePicker(L10n.text("overview.end_date"), selection: Binding(
                        get: { navigation.overviewSelection.range().end },
                        set: { navigation.overviewSelection.setCustomEnd($0) }
                    ), in: available, displayedComponents: .date)
                }.datePickerStyle(.compact).controlSize(.small)
                    .frame(maxWidth: .infinity)
            }
            Text(L10n.text("overview.dates", dateLabel(range.start), dateLabel(range.end)))
                .font(.callout).monospacedDigit()
            Text(L10n.text("overview.help")).font(.callout).foregroundStyle(.secondary)
            if !summary.hasRecords {
                Text(L10n.text("overview.empty")).font(.callout).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                metric("overview.usage", L10n.duration(summary.usage))
                metric("overview.completed", L10n.text("overview.count", summary.completed))
                metric("overview.rest", L10n.duration(summary.rest))
                metric("overview.skipped", L10n.text("overview.count", summary.skipped))
                metric("plan.focus_completed", L10n.text("overview.count", summary.focusCompleted))
                metric("plan.ended_count", L10n.text("overview.count", summary.ended))
            }
            Text(L10n.text("overview.natural", L10n.duration(summary.natural))).font(.callout)
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text("overview.retention"))
                if range.start <= available.lowerBound {
                    Text(L10n.text("overview.partial_day"))
                }
                Text(L10n.text("overview.disclaimer"))
            }.font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }
    private func dateLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = model.interfaceLocale
        formatter.calendar = Calendar.current
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(L10n.text(title)).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3).monospacedDigit()
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct WelcomeView: View {
    @ObservedObject var model: AppController
    let finish: () -> Void
    let layoutChanged: () -> Void
    @State private var step = 0
    @State private var selectedPlan: RestPlanID = .tickrest
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Image(systemName: "leaf.fill").font(.title).foregroundStyle(.orange)
                Text(L10n.text("welcome.title")).font(.title2.bold())
            }
            Text(L10n.text("welcome.step", step + 1)).font(.caption).foregroundStyle(.secondary)
            if step == 0 {
                Text(L10n.text("welcome.rhythm")).font(.headline)
                Picker(L10n.text("plan.choose"), selection: $selectedPlan) {
                    ForEach(RestPlanID.allCases) { plan in Text(plan.title).tag(plan) }
                }
                Text(selectedPlan.description).font(.body).foregroundStyle(.secondary)
                Text(L10n.text("plan.health_note")).font(.caption).foregroundStyle(.secondary)
            } else if step == 1 {
                Text(L10n.text("welcome.style")).font(.headline)
                Picker(L10n.text("reminder.style"), selection: Binding(get: { model.settings.style }, set: { v in model.update { $0.style = v } })) {
                    ForEach(ReminderStyle.allCases, id: \.self) { Text(L10n.text("style.\($0.rawValue)")).tag($0) }
                }.pickerStyle(.segmented)
                Text(L10n.text("reminder.style_help")).foregroundStyle(.secondary)
                Picker(L10n.text("reminder.start_mode"), selection: Binding(get: { model.settings.breakStartMode }, set: { v in model.update { $0.breakStartMode = v } })) {
                    ForEach(BreakStartMode.allCases, id: \.self) { Text(L10n.text("start_mode.\($0.rawValue)")).tag($0) }
                }.pickerStyle(.segmented)
                Text(L10n.text("reminder.start_mode_help")).font(.caption).foregroundStyle(.secondary)
                Button(L10n.text("reminder.preview")) { NotificationCenter.default.post(name: .previewRest, object: nil) }
            } else {
                Text(L10n.text("welcome.ready")).font(.headline)
                Text(L10n.text("welcome.menu_help")).foregroundStyle(.secondary)
                Toggle(L10n.text("general.login"), isOn: Binding(get: { model.launchAtLogin }, set: model.setLogin))
                Button(L10n.text("general.request_notifications")) { model.requestNotifications() }
                Text(L10n.text("general.notifications_help")).font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                if step > 0 { Button(L10n.text("common.back")) { step -= 1 } }
                Spacer()
                Button(L10n.text(step == 2 ? "welcome.begin" : "common.next")) { if step == 2 { finish() } else { if step == 0 { model.applyPlan(.preset(selectedPlan)) }; step += 1 } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 580)
            .fixedSize(horizontal: false, vertical: true)
            .tint(.orange)
            .environment(\.locale, L10n.locale)
            .onChange(of: step) { _ in
                DispatchQueue.main.async(execute: layoutChanged)
            }
    }
}
