import SwiftUI
import TickRestCore

private let restColor = Color(red: 0.12, green: 0.28, blue: 0.21)

// Nonactivating panels need explicit colors for every action, independent of window focus.
private struct RestCardButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(prominent ? restColor : Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.5)
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct RestCard: View {
    @ObservedObject var model: AppController
    let preview: Bool
    let previewEnd: () -> Void
    private var r: Reminder { model.engine.reminder ?? Reminder(kind: .short, target: 5) }
    var body: some View {
        VStack(spacing: 15) {
            HStack {
                Label(r.kind.title, systemImage: r.kind == .short ? "eye" : "figure.walk")
                Spacer()
                Button { close() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel(L10n.text("common.close"))
            }.font(.callout.bold())
            Text(preview ? "00:05" : L10n.clock(r.target - r.elapsed)).font(.system(size: 52, weight: .regular, design: .rounded)).monospacedDigit()
                .accessibilityLabel(L10n.text("rest.remaining", L10n.duration(r.target - r.elapsed)))
            Text(L10n.text(preview ? "rest.preview" : model.engine.isResting ? "rest.running" : "rest.waiting"))
                .font(.caption).foregroundStyle(.secondary)
            Text(r.idea)
                .font(.callout).multilineTextAlignment(.center).frame(maxWidth: .infinity).fixedSize(horizontal: false, vertical: true)
            HStack {
                if preview {
                    Button(L10n.text("common.close"), action: previewEnd)
                } else if model.engine.isResting {
                    Button(L10n.text("rest.end")) { model.action { $0.finish(now: Date()) } }
                        .buttonStyle(RestCardButtonStyle(prominent: true))
                } else {
                    Button(L10n.text("rest.start")) { model.action { $0.start(now: Date()) } }
                        .buttonStyle(RestCardButtonStyle(prominent: true))
                    if r.postponements < 2 {
                        Button(L10n.text("rest.defer", Int(r.kind.postponement / 60))) { model.action { $0.postpone(now: Date()) } }
                    }
                    Button(L10n.text("rest.skip")) { model.action { $0.skip(now: Date()) } }
                }
            }.buttonStyle(RestCardButtonStyle())
        }.padding(24).frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.secondary.opacity(0.2)))
            .padding(1).tint(restColor)
    }
    private func close() { if preview { previewEnd() } else { model.action { $0.skip(now: Date()) } } }
}

struct OverlayView: View {
    @ObservedObject var model: AppController
    let preview: Bool
    let primary: Bool
    let previewEnd: () -> Void
    private var r: Reminder { model.engine.reminder ?? Reminder(kind: .short, target: 5) }
    var body: some View {
        VStack(spacing: 25) {
            if primary { Image(systemName: r.kind == .short ? "leaf" : "figure.walk").font(.system(size: 40)).accessibilityHidden(true) }
            Text(r.kind.title).font(.title2)
            Text(preview ? "00:05" : L10n.clock(r.target - r.elapsed)).font(.system(size: primary ? 88 : 52, weight: .light, design: .rounded)).monospacedDigit()
            if primary {
                Text(preview ? L10n.text("rest.preview") : r.idea)
                    .font(.title3).multilineTextAlignment(.center).frame(maxWidth: 600)
                HStack(spacing: 16) {
                    if preview { Button(L10n.text("common.close"), action: previewEnd) }
                    else {
                        if r.elapsed <= 5 && r.postponements < 2 {
                            Button(L10n.text("rest.defer", Int(r.kind.postponement / 60))) { model.action { $0.postpone(now: Date()) } }
                        }
                        Button(L10n.text("rest.end")) { model.action { $0.finish(now: Date()) } }
                    }
                }.buttonStyle(.bordered).controlSize(.large)
                Text(L10n.text("rest.escape")).font(.caption).foregroundStyle(.white.opacity(0.7))
            }
        }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(Color(red: 0.91, green: 0.95, blue: 0.84))
            .background(Color(red: 0.10, green: 0.18, blue: 0.15))
            .preferredColorScheme(.dark)
    }
}

struct WarningView: View {
    let kind: BreakKind
    let settings: TickRestCore.Settings
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "leaf").font(.title2).foregroundStyle(restColor)
            VStack(alignment: .leading, spacing: 7) {
                Text(L10n.text("app.name")).font(.callout.bold())
                Text(L10n.text("warning.body", Int(settings.prewarning), kind.title, L10n.duration(settings.duration(kind)))).font(.callout)
            }
            Spacer(minLength: 0)
        }.padding(17).frame(maxWidth: .infinity, maxHeight: .infinity).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)).padding(1)
    }
}

struct TodayView: View {
    @ObservedObject var model: AppController
    var body: some View {
        let summary = model.summary
        VStack(alignment: .leading, spacing: 20) {
            Text(L10n.text("today.help")).font(.callout).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                metric("today.usage", L10n.duration(summary.usage))
                metric("today.completed", L10n.text("today.count", summary.completed))
                metric("today.rest", L10n.duration(summary.rest))
                metric("today.skipped", L10n.text("today.count", summary.skipped))
            }
            Text(L10n.text("today.natural", L10n.duration(summary.natural))).font(.callout)
            Text(L10n.text("today.disclaimer")).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .topLeading)
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
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Image(systemName: "leaf.fill").font(.title).foregroundStyle(.orange)
                Text(L10n.text("welcome.title")).font(.title2.bold())
            }
            Text(L10n.text("welcome.step", step + 1)).font(.caption).foregroundStyle(.secondary)
            if step == 0 {
                Text(L10n.text("welcome.rhythm")).font(.headline)
                Text(L10n.text("welcome.rhythm_help")).font(.body).foregroundStyle(.secondary)
                Toggle(L10n.text("break.short"), isOn: Binding(get: { model.settings.shortEnabled }, set: { v in model.update { $0.shortEnabled = v } }))
                Toggle(L10n.text("break.long"), isOn: Binding(get: { model.settings.longEnabled }, set: { v in model.update { $0.longEnabled = v } }))
            } else if step == 1 {
                Text(L10n.text("welcome.style")).font(.headline)
                Picker(L10n.text("reminder.style"), selection: Binding(get: { model.settings.style }, set: { v in model.update { $0.style = v } })) {
                    ForEach(ReminderStyle.allCases, id: \.self) { Text(L10n.text("style.\($0.rawValue)")).tag($0) }
                }.pickerStyle(.segmented)
                Text(L10n.text("reminder.style_help")).foregroundStyle(.secondary)
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
                Button(L10n.text(step == 2 ? "welcome.begin" : "common.next")) { if step == 2 { finish() } else { step += 1 } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 580)
            .fixedSize(horizontal: false, vertical: true)
            .tint(.orange)
            .onChange(of: step) { _ in
                DispatchQueue.main.async(execute: layoutChanged)
            }
    }
}
