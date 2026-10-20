import AppKit
import ServiceManagement
import UserNotifications
import TickRestCore

/// System boundaries are replaceable so permission flows can be tested without
/// opening an application, changing login items or prompting for permission.
struct SystemAccess {
    var notificationsAvailable: Bool
    var notificationStatus: (@escaping (UNAuthorizationStatus) -> Void) -> Void
    var requestNotifications: (@escaping (Error?) -> Void) -> Void
    var installNotificationDelegate: (UNUserNotificationCenterDelegate) -> Void
    var addNotification: (UNNotificationRequest, @escaping (Error?) -> Void) -> Void
    var openNotificationSettings: () -> Bool
    var loginStatus: () -> SMAppService.Status
    var registerLogin: () throws -> Void
    var unregisterLogin: () throws -> Void
    var openLoginSettings: () -> Void

    static var live: Self {
        Self(
            notificationsAvailable: Bundle.main.bundleURL.pathExtension == "app",
            notificationStatus: { completion in
                UNUserNotificationCenter.current().getNotificationSettings { completion($0.authorizationStatus) }
            },
            requestNotifications: { completion in
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in completion(error) }
            },
            installNotificationDelegate: { UNUserNotificationCenter.current().delegate = $0 },
            addNotification: { UNUserNotificationCenter.current().add($0, withCompletionHandler: $1) },
            openNotificationSettings: {
                for path in ["com.apple.Notifications-Settings.extension", "com.apple.preference.notifications"] {
                    if let url = URL(string: "x-apple.systempreferences:" + path), NSWorkspace.shared.open(url) { return true }
                }
                return false
            },
            loginStatus: { SMAppService.mainApp.status },
            registerLogin: { try SMAppService.mainApp.register() },
            unregisterLogin: { try SMAppService.mainApp.unregister() },
            openLoginSettings: { SMAppService.openSystemSettingsLoginItems() }
        )
    }
}

final class ReminderNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static func presentationOptions(for identifier: String) -> UNNotificationPresentationOptions {
        identifier == AppIdentity.identifier("prewarning") ? [.banner, .list] : []
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(Self.presentationOptions(for: notification.request.identifier))
    }
}
