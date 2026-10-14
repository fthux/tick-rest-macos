import SwiftUI
import TickRestCore

struct WelcomeView: View {
    @ObservedObject var model: AppController
    let finish: () -> Void
    let layoutChanged: () -> Void
    @State private var step = 0
    @State private var selectedPlan: RestPlanID = .tickrest
    @State private var showingOptions = false

    init(model: AppController, finish: @escaping () -> Void, layoutChanged: @escaping () -> Void) {
        self.model = model
        self.finish = finish
        self.layoutChanged = layoutChanged
        _selectedPlan = State(initialValue: model.settings.planID == .custom ? .tickrest : model.settings.planID)
    }

    private var nextTitle: String {
        L10n.text(step == 0 ? "welcome.configure" : step == 1 ? "welcome.use_plan" : step == 3 ? "welcome.begin" : "common.next")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                Image(systemName: "leaf.fill").font(.title).foregroundStyle(.orange)
                Text(L10n.text("welcome.title")).font(.title2.bold())
            }
            HStack(spacing: 8) {
                ForEach(0..<4) { index in
                    Capsule().fill(index <= step ? Color.orange : Color.secondary.opacity(0.15))
                        .frame(width: 28, height: 4)
                }
                Text(L10n.text("welcome.step", step + 1)).font(.caption).foregroundStyle(.secondary)
            }
            Group {
                switch step {
                case 0: introduction
                case 1: plans
                case 2: styles
                default: ready
                }
            }
            Divider()
            HStack {
                if step > 0 { Button(L10n.text("common.back")) { step -= 1 } }
                Spacer()
                Button(nextTitle) {
                    if step == 3 {
                        model.completeOnboarding(plan: .preset(selectedPlan))
                        finish()
                    } else {
                        if step == 1 { model.update { $0.restPlan = .preset(selectedPlan) } }
                        step += 1
                    }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(28).frame(width: 580)
        .fixedSize(horizontal: false, vertical: true)
        .tint(.orange).environment(\.locale, L10n.locale)
        .onChange(of: step) { _ in resize() }
        .onChange(of: showingOptions) { _ in resize() }
        .onChange(of: model.interfaceLanguage) { _ in resize() }
    }

    private func resize() { DispatchQueue.main.async(execute: layoutChanged) }

    private func heading(_ key: String) -> some View {
        Text(L10n.text(key)).font(.system(size: 23, weight: .semibold))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading("welcome.intro_title")
            Text(L10n.text("welcome.intro_body")).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                VStack(spacing: 10) {
                    Image(systemName: "laptopcomputer").font(.system(size: 30)).foregroundStyle(.orange)
                    Text(L10n.text("welcome.work")).font(.headline)
                    Text(L10n.duration(RestPlan().shortInterval)).font(.title2).monospacedDigit()
                }.frame(maxWidth: .infinity)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                VStack(spacing: 10) {
                    Image(systemName: "eye").font(.system(size: 30)).foregroundStyle(.orange)
                    Text(L10n.text("break.short")).font(.headline)
                    Text(L10n.duration(RestPlan().shortDuration)).font(.title2).monospacedDigit()
                }.frame(maxWidth: .infinity)
            }
            .padding(24).background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
            Label(L10n.text("welcome.adjust_later"), systemImage: "leaf")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var plans: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading("welcome.rhythm")
            Text(L10n.text("welcome.plan_help")).foregroundStyle(.secondary)
            ForEach(RestPlanID.allCases.filter { $0 != .custom }) { plan in
                Button { selectedPlan = plan } label: {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: selectedPlan == plan ? "checkmark.circle.fill" : "circle")
                            .font(.title3).foregroundStyle(selectedPlan == plan ? Color.orange : .secondary)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(plan == .tickrest ? L10n.text("welcome.recommended_plan") : plan.title)
                                .font(.headline)
                            Text(L10n.text("welcome.plan.\(plan.rawValue)"))
                                .font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(selectedPlan == plan ? Color.orange.opacity(0.08) : Color.secondary.opacity(0.04),
                                    in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(selectedPlan == plan ? Color.orange : Color.secondary.opacity(0.15)))
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain)
                    .accessibilityLabel(plan == .tickrest ? L10n.text("welcome.recommended_plan") : plan.title)
                    .accessibilityHint(L10n.text("welcome.plan.\(plan.rawValue)"))
                    .accessibilityAddTraits(selectedPlan == plan ? [.isSelected] : [])
            }
            Text(L10n.text("welcome.custom_later")).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var styles: some View {
        VStack(alignment: .leading, spacing: 16) {
            heading("welcome.style")
            HStack(alignment: .top, spacing: 12) {
                styleCard(.overlay)
                styleCard(.gentle)
            }
            Button(L10n.text("reminder.preview")) {
                // The chosen plan is available to the preview without starting the scheduler.
                NotificationCenter.default.post(name: .previewRest, object: nil)
            }
            Text(L10n.text("welcome.preview_help")).font(.caption).foregroundStyle(.secondary)
            DisclosureGroup(L10n.text("welcome.more_options"), isExpanded: $showingOptions) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker(L10n.text("reminder.start_mode"), selection: Binding(
                        get: { model.settings.breakStartMode },
                        set: { value in model.update { $0.breakStartMode = value } }
                    )) {
                        ForEach(BreakStartMode.allCases, id: \.self) {
                            Text(L10n.text("start_mode.\($0.rawValue)")).tag($0)
                        }
                    }.pickerStyle(.segmented)
                    Text(L10n.text("reminder.start_mode_help")).font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 10)
            }
        }
    }

    private func styleCard(_ style: ReminderStyle) -> some View {
        let selected = model.settings.style == style
        let backgroundHelp = L10n.text("welcome.background_help", L10n.text("settings.appearance"))
        return Button { model.update { $0.style = style } } label: {
            VStack(alignment: .leading, spacing: 12) {
                WelcomeStyleThumbnail(style: style)
                HStack(spacing: 6) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Color.orange : .secondary)
                    Text(L10n.text("style.\(style.rawValue)")).font(.headline)
                    if style == .overlay {
                        Text(L10n.text("welcome.default")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(L10n.text("welcome.style.\(style.rawValue)"))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if style == .overlay {
                    Text(backgroundHelp).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.orange.opacity(0.08) : Color.secondary.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(selected ? Color.orange : Color.secondary.opacity(0.15)))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain)
            .accessibilityLabel(L10n.text("style.\(style.rawValue)"))
            .accessibilityHint(L10n.text("welcome.style.\(style.rawValue)") + (style == .overlay ? " " + backgroundHelp : ""))
            .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 16) {
            heading("welcome.ready")
            HStack(spacing: 10) {
                Text(L10n.text("welcome.menu_location")).font(.callout)
                Spacer()
                Image(systemName: "leaf.fill").foregroundStyle(.orange)
                Text(L10n.clock(RestPlan.preset(selectedPlan).shortInterval)).monospacedDigit()
                Image(systemName: "wifi")
                Image(systemName: "battery.100percent")
            }
            .padding(12).background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            Text(L10n.text("welcome.menu_help")).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                Label(selectedPlan == .tickrest ? L10n.text("welcome.recommended_plan") : selectedPlan.title,
                      systemImage: "checkmark.circle")
                Text(L10n.text("welcome.plan.\(selectedPlan.rawValue)"))
                    .font(.callout).foregroundStyle(.secondary)
                Label(L10n.text("style.\(model.settings.style.rawValue)") + " · " +
                      L10n.text("start_mode.\(model.settings.breakStartMode.rawValue)"), systemImage: "display")
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
            Text(L10n.text("welcome.optional")).font(.caption).foregroundStyle(.secondary)
            Toggle(L10n.text("general.login"), isOn: Binding(get: { model.launchAtLogin }, set: model.setLogin))
            Button(L10n.text("general.request_notifications")) { model.requestNotifications() }
            Text(L10n.text("general.notifications_help")).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.text("welcome.start_help")).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// A schematic preview stays inside onboarding; actual fullscreen previews are opt-in.
private struct WelcomeStyleThumbnail: View {
    let style: ReminderStyle
    private let gradient = OverlayBackground().gradient
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.10))
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    ForEach(0..<3) { _ in Circle().fill(Color.secondary.opacity(0.35)).frame(width: 5, height: 5) }
                    Spacer()
                    Image(systemName: "leaf.fill").font(.system(size: 8))
                }
                RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.12)).frame(width: 80, height: 8)
                RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.12)).frame(height: 40)
                Spacer(minLength: 0)
            }.padding(10)
            if style == .overlay {
                BackgroundGradientView(gradient: gradient)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(spacing: 7) {
                    Image(systemName: "eye").font(.title3)
                    Text("00:20").font(.system(size: 24, weight: .light, design: .rounded)).monospacedDigit()
                    Capsule().fill(.white.opacity(0.25)).frame(width: 40, height: 5)
                }.foregroundStyle(.white)
            } else {
                VStack {
                    HStack(spacing: 8) {
                        Image(systemName: "eye")
                        Text("00:20").monospacedDigit()
                    }.font(.caption).padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.secondary.opacity(0.2)))
                    Spacer()
                }.padding(14)
            }
        }.frame(height: 126).accessibilityHidden(true)
    }
}
