import Foundation
import UserNotifications
import TickRestCore

/// Runs in the replacement app, using its existing notification permission and delegate.
@MainActor struct UpdateCompletionNotification {
    static let identifier = AppIdentity.identifier("updateCompleted")
    static let handledSignal = "completionNotificationHandled.json"
    let system: SystemAccess
    let app: URL
    let jobsRoot: URL

    init(system: SystemAccess = .live, app: URL = Bundle.main.bundleURL, jobsRoot: URL = UpdateJobStore.root) {
        self.system = system; self.app = app; self.jobsRoot = jobsRoot
    }

    func notifyWhenCompleted(_ store: UpdateJobStore, timeout: TimeInterval = 30) async {
        guard !Task.isCancelled,
              let job = try? store.validatedJob(root: jobsRoot),
              job.installation.app.standardizedFileURL.resolvingSymlinksInPath() == app.standardizedFileURL.resolvingSymlinksInPath(),
              store.hasSignal("approved.json"), store.hasSignal("started.json") else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while store.state?.phase == .relaunching {
            guard Date() < deadline else { return }
            do { try await Task.sleep(nanoseconds: 200_000_000) }
            catch { return }
        }
        guard !Task.isCancelled, store.state?.phase == .completed,
              !store.hasSignal(Self.handledSignal),
              (try? HomebrewUpgradeEngine.verifyApplication(app, required: job.required,
                  architecture: job.installation.architecture, channel: job.installation.channel)) != nil,
              let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = info["CFBundleShortVersionString"] as? String else { return }
        // Mark before awaiting permission/delivery so repeated checks cannot enqueue duplicates.
        // Denied permission is also handled: a later app launch must not show an old success.
        do { try store.signal(Self.handledSignal) }
        catch { return }
        guard system.notificationsAvailable else { return }
        let status = await withCheckedContinuation { continuation in
            system.notificationStatus { continuation.resume(returning: $0) }
        }
        guard !Task.isCancelled, store.state?.phase == .completed,
              status == .authorized || status == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = L10n.text("update.notification_title")
        content.body = L10n.text("update.notification_body", version)
        let request = UNNotificationRequest(identifier: Self.identifier, content: content, trigger: nil)
        // Notification failures never change a successfully installed update into an error.
        system.addNotification(request) { error in
            if let error { store.appendLog("Update notification unavailable: \(error.localizedDescription)\n") }
        }
    }
}
