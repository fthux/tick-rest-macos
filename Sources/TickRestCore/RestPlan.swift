import Foundation

public enum RestPlanID: String, Codable, CaseIterable, Identifiable {
    case tickrest, eye202020, fiftyTen, pomodoro, custom
    public var id: String { rawValue }
    public var title: String { L10n.text("plan.\(rawValue)") }
    public var description: String { L10n.text("plan.\(rawValue).description") }
    public var sourceURL: URL? {
        switch self {
        case .eye202020: return URL(string: "https://www.aao.org/eye-health/tips-prevention/computer-usage")
        case .pomodoro: return URL(string: "https://www.pomodorotechnique.com/")
        default: return nil
        }
    }
}

public enum TimingModel: String, Codable, CaseIterable, Identifiable {
    case dual, single, rounds
    public var id: String { rawValue }
    public var title: String { L10n.text("timing.\(rawValue)") }
}

/// Only routine settings belong here. Applying a routine never overwrites display,
/// language, sound, idle detection, work hours, or other application preferences.
public struct RestPlan: Codable, Equatable {
    public var id: RestPlanID = .tickrest
    public var baseID: RestPlanID? = nil
    public var model: TimingModel = .dual
    public var shortEnabled = true
    public var longEnabled = true
    public var shortInterval: Double = 1200
    public var shortDuration: Double = 20
    public var longInterval: Double = 3600
    public var longDuration: Double = 300
    public var rounds = 4
    public var shortPostpone: Double = 120
    public var longPostpone: Double = 300
    public var singlePostpone: Double = 300
    public var postponeLimit = 2
    public init() {}

    public static func preset(_ id: RestPlanID) -> RestPlan {
        var p = RestPlan(); p.id = id
        switch id {
        case .tickrest, .custom: break
        case .eye202020:
            p.model = .single; p.longEnabled = false
        case .fiftyTen:
            p.model = .single; p.longEnabled = false
            p.shortInterval = 3000; p.shortDuration = 600
        case .pomodoro:
            p.model = .rounds; p.shortInterval = 1500; p.shortDuration = 300; p.longDuration = 900
        }
        return p
    }
    public var title: String {
        if id == .custom, let baseID, baseID != .custom { return L10n.text("plan.based_on", baseID.title) }
        return id.title
    }
    public mutating func markCustom() {
        if id != .custom { baseID = id; id = .custom }
    }
    public func enabled(_ kind: BreakKind) -> Bool {
        switch model {
        case .dual: return kind == .short ? shortEnabled : longEnabled
        case .single: return kind == .short
        case .rounds: return true
        }
    }
    public func duration(_ kind: BreakKind) -> Double { kind == .short ? shortDuration : longDuration }
    public func postponement(_ kind: BreakKind) -> Double {
        model == .single ? singlePostpone : kind == .short ? shortPostpone : longPostpone
    }
    public func breakTitle(_ kind: BreakKind) -> String {
        if model == .rounds { return L10n.text(kind == .short ? "plan.short_break" : "plan.long_break") }
        if model == .single { return L10n.text(id == .eye202020 || baseID == .eye202020 ? "break.short" : "plan.break") }
        return kind.title
    }
    public var validationErrorKey: String? {
        guard shortInterval.isFinite, shortDuration.isFinite, longInterval.isFinite, longDuration.isFinite,
              (60...7200).contains(shortInterval), (10...(model == .dual ? 300 : 1800)).contains(shortDuration),
              (60...14400).contains(longInterval), (60...1800).contains(longDuration),
              (2...12).contains(rounds), (0...10).contains(postponeLimit),
              [shortPostpone, longPostpone, singlePostpone].allSatisfy({ $0.isFinite && (60...1800).contains($0) })
        else { return "validation.range" }
        if model == .dual && shortEnabled && longEnabled && longInterval < shortInterval { return "validation.interval" }
        if model != .single && enabled(.short) && enabled(.long) && longDuration < shortDuration {
            return model == .rounds ? "validation.round_duration" : "validation.duration"
        }
        return nil
    }
}

extension Settings {
    public var restPlan: RestPlan {
        get {
            var p = RestPlan()
            p.id = planID; p.baseID = basePlanID; p.model = timingModel
            p.shortEnabled = shortEnabled; p.longEnabled = longEnabled
            p.shortInterval = shortInterval; p.shortDuration = shortDuration
            p.longInterval = longInterval; p.longDuration = longDuration
            p.rounds = rounds; p.shortPostpone = shortPostpone; p.longPostpone = longPostpone
            p.singlePostpone = singlePostpone; p.postponeLimit = postponeLimit
            return p
        }
        set {
            planID = newValue.id; basePlanID = newValue.baseID; timingModel = newValue.model
            shortEnabled = newValue.shortEnabled; longEnabled = newValue.longEnabled
            shortInterval = newValue.shortInterval; shortDuration = newValue.shortDuration
            longInterval = newValue.longInterval; longDuration = newValue.longDuration
            rounds = newValue.rounds; shortPostpone = newValue.shortPostpone; longPostpone = newValue.longPostpone
            singlePostpone = newValue.singlePostpone; postponeLimit = newValue.postponeLimit
        }
    }
    public var previewReminder: Reminder {
        let kind: BreakKind = enabled(.short) ? .short : enabled(.long) ? .long : .short
        var r = Reminder(kind: kind, target: 5)
        r.planID = planID; r.basePlanID = basePlanID; r.timingModel = timingModel
        return r
    }
    public func breakTitle(_ kind: BreakKind) -> String { restPlan.breakTitle(kind) }
    public func postponement(_ kind: BreakKind) -> Double { restPlan.postponement(kind) }
}
