import Foundation

/// Retains each token together with the center responsible for removing it.
final class NotificationObservations {
    private var registrations: [(NotificationCenter, NSObjectProtocol)] = []

    func observe(_ center: NotificationCenter, name: Notification.Name,
                 queue: OperationQueue? = .main, using handler: @escaping (Notification) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: queue, using: handler)
        registrations.append((center, token))
    }

    deinit {
        for (center, token) in registrations { center.removeObserver(token) }
    }
}
