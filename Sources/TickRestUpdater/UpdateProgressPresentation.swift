import TickRestCore

extension UpdateJobState.Phase {
    /// Overall progress by stage, rather than a download byte percentage.
    /// Failure and cancellation retain the last completed stage's position.
    var progressFraction: Double? {
        switch self {
        case .preparing: return 0.05
        case .refreshing: return 0.15
        case .downloading: return 0.3
        case .waiting: return 0.5
        case .installing: return 0.6
        case .verifying: return 0.85
        case .relaunching: return 0.95
        case .completed: return 1
        case .failed, .cancelled: return nil
        }
    }

    var progressHelpKey: String {
        switch self {
        case .waiting: return "update.waiting_help"
        case .completed: return "update.completed_help"
        case .failed, .cancelled: return "update.finished_help"
        default: return "update.progress_help"
        }
    }
}
