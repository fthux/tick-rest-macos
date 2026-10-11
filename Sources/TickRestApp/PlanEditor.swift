import SwiftUI
import TickRestCore

/// A local draft avoids partially applied intervals and invalid intermediate settings.
struct PlanEditor: View {
    @ObservedObject var model: AppController
    @State private var draft = RestPlan()
    @State private var reference = RestPlan()
    private var changed: Bool { draft != reference }
    private var validation: String? {
        var candidate = model.settings; candidate.restPlan = draft
        return candidate.validationErrorKey
    }
    var body: some View {
        Group {
            Section {
                LabeledContent(L10n.text("plan.active"), value: model.settings.restPlan.title)
                if let pending = model.engine.pendingPlan {
                    Text(L10n.text("plan.pending", pending.title)).font(.callout)
                    Button(L10n.text("plan.cancel_pending")) { model.cancelPendingPlan(); reload() }
                }
                Picker(L10n.text("plan.choose"), selection: Binding(
                    get: { draft.id }, set: { id in
                        if id == .custom { draft.markCustom() }
                        else { draft = .preset(id) }
                    }
                )) {
                    ForEach(RestPlanID.allCases) { plan in Text(plan.title).tag(plan) }
                }
                Text(draft.title).font(.headline)
                Text(L10n.text("plan.reference")).font(.caption).foregroundStyle(.secondary)
                Text((draft.baseID ?? draft.id).description).font(.callout).foregroundStyle(.secondary)
                if let source = (draft.baseID ?? draft.id).sourceURL { Link(L10n.text("plan.learn_more"), destination: source).font(.caption) }
                Text(L10n.text("plan.health_note")).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker(L10n.text("plan.model"), selection: binding(\.model)) {
                    ForEach(TimingModel.allCases) { timing in Text(timing.title).tag(timing) }
                }
                if draft.model == .dual {
                    Toggle(L10n.text("break.short"), isOn: binding(\.shortEnabled))
                    duration("rhythm.interval_minutes", \.shortInterval, range: 60...7200, step: 60, minutes: true)
                        .disabled(!draft.shortEnabled)
                    duration("rhythm.duration_seconds", \.shortDuration, range: 10...300, step: 5)
                        .disabled(!draft.shortEnabled)
                    Toggle(L10n.text("break.long"), isOn: binding(\.longEnabled))
                    duration("rhythm.interval_minutes", \.longInterval, range: 60...14400, step: 60, minutes: true)
                        .disabled(!draft.longEnabled)
                    duration("rhythm.duration_minutes", \.longDuration, range: 60...1800, step: 60, minutes: true)
                        .disabled(!draft.longEnabled)
                    Text(L10n.text("rhythm.merge_help")).font(.caption).foregroundStyle(.secondary)
                } else {
                    duration(draft.model == .rounds ? "plan.focus_minutes" : "plan.work_minutes", \.shortInterval, range: 60...7200, step: 60, minutes: true)
                    duration(draft.model == .rounds ? "plan.short_seconds" : "rhythm.duration_seconds", \.shortDuration, range: 10...1800, step: 5)
                    if draft.model == .rounds {
                        duration("plan.long_minutes", \.longDuration, range: 60...1800, step: 60, minutes: true)
                        Stepper(value: binding(\.rounds), in: 2...12) { Text(L10n.text("plan.rounds", draft.rounds)) }
                        Text(L10n.text("plan.rounds_help")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Text(L10n.text("rhythm.help")).font(.callout)
                Text(L10n.text("plan.actions_help")).font(.caption).foregroundStyle(.secondary)
                Text(L10n.text(draft.model == .rounds ? "plan.rounds_away" : "plan.away_help")).font(.caption).foregroundStyle(.secondary)
                Text(L10n.text("plan.switch_help")).font(.caption).foregroundStyle(.secondary)
                DisclosureGroup(L10n.text("plan.advanced")) {
                    if draft.model == .single {
                        duration("plan.postpone_minutes", \.singlePostpone, range: 60...1800, step: 60, minutes: true)
                    } else {
                        duration("plan.postpone_short", \.shortPostpone, range: 60...1800, step: 60, minutes: true)
                        duration("plan.postpone_long", \.longPostpone, range: 60...1800, step: 60, minutes: true)
                    }
                    Stepper(value: binding(\.postponeLimit), in: 0...10) { Text(L10n.text("plan.postpone_limit", draft.postponeLimit)) }
                    Text(L10n.text("plan.cooldown_help")).font(.caption).foregroundStyle(.secondary)
                }.controlSize(.small)
            }
            Section {
                if let validation { Text(L10n.text(validation)).font(.callout).foregroundStyle(.red) }
                HStack {
                    Button(L10n.text("plan.restore")) { draft = .preset(draft.baseID ?? draft.id) }
                    Spacer()
                    Button(L10n.text("common.cancel")) { reload() }.disabled(!changed)
                    Button(L10n.text("plan.apply")) { model.applyPlan(draft); reload() }
                        .buttonStyle(.borderedProminent).disabled(!changed || validation != nil)
                }
            }
        }
        .onAppear { reload() }
        .onChange(of: model.settings.restPlan) { _ in if !changed { reload() } }
    }
    private func reload() {
        draft = model.engine.pendingPlan ?? model.settings.restPlan; reference = draft
    }
    private func binding<T>(_ key: WritableKeyPath<RestPlan, T>) -> Binding<T> {
        Binding(get: { draft[keyPath: key] }, set: { value in
            draft[keyPath: key] = value; draft.markCustom()
            if draft.model == .dual { draft.shortDuration = min(300, draft.shortDuration) }
        })
    }
    private func duration(_ key: String, _ path: WritableKeyPath<RestPlan, Double>, range: ClosedRange<Double>, step: Double, minutes: Bool = false) -> some View {
        Stepper(value: binding(path), in: range, step: step) {
            if path == \RestPlan.shortDuration {
                Text(L10n.text(draft.model == .rounds ? "plan.short_duration" : "plan.break_duration", L10n.duration(draft.shortDuration)))
            } else { Text(L10n.text(key, Int(draft[keyPath: path] / (minutes ? 60 : 1)))) }
        }
    }
}
