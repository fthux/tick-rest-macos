import AppKit
import ServiceManagement
import UserNotifications
import XCTest
import TickRestCore
@testable import TickRestApp

/// All system calls are fakes. Do not initialize NSApplication or call begin().
@MainActor
final class SystemAccessTests: XCTestCase {
    private final class FakeSystem {
        var available = true
        var authorization: UNAuthorizationStatus = .notDetermined
        var requestedAuthorization: UNAuthorizationStatus = .authorized
        var login: SMAppService.Status = .notRegistered
        var requestCount = 0, settingsCount = 0, registerCount = 0, unregisterCount = 0, loginSettingsCount = 0
        var requestError: Error?, loginError: Error?, deliveryError: Error?
        var opensSettings = true
        weak var delegate: UNUserNotificationCenterDelegate?
        var requests: [UNNotificationRequest] = []
        var access: SystemAccess {
            SystemAccess(notificationsAvailable: available,
                notificationStatus: { $0(self.authorization) },
                requestNotifications: {
                    self.requestCount += 1
                    if self.requestError == nil { self.authorization = self.requestedAuthorization }
                    $0(self.requestError)
                },
                installNotificationDelegate: { self.delegate = $0 },
                addNotification: { self.requests.append($0); $1(self.deliveryError) },
                openNotificationSettings: { self.settingsCount += 1; return self.opensSettings },
                loginStatus: { self.login },
                registerLogin: {
                    self.registerCount += 1
                    if let error = self.loginError { throw error }
                    self.login = .requiresApproval
                },
                unregisterLogin: {
                    self.unregisterCount += 1
                    if let error = self.loginError { throw error }
                    self.login = .notRegistered
                },
                openLoginSettings: { self.loginSettingsCount += 1 })
        }
    }
    private func withModel(_ fake: FakeSystem, _ body: (AppController) async throws -> Void) async rethrows {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("permissions-\(UUID())")
        let language = L10n.language
        defer { L10n.language = language; try? FileManager.default.removeItem(at: directory) }
        let model = AppController(store: DataStore(url: directory.appendingPathComponent("state.json")), systemAccess: fake.access)
        await flushCallbacks()
        try await body(model)
    }
    private func flushCallbacks() async {
        // Initial status -> action -> request result -> refreshed status.
        for _ in 0..<4 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
    func testInitialPermissionRequestAndDuplicateClickGuard() async {
        for result: UNAuthorizationStatus in [.authorized, .denied] {
            let fake = FakeSystem(); fake.requestedAuthorization = result
            await withModel(fake) { model in
                XCTAssertEqual(model.notificationActionTitle, "general.request_notifications")
                model.requestNotifications(); model.requestNotifications()
                XCTAssertFalse(model.canManageNotifications)
                await flushCallbacks()
                XCTAssertEqual(fake.requestCount, 1)
                XCTAssertEqual(fake.settingsCount, 0)
                XCTAssertTrue(model.canManageNotifications)
                XCTAssertEqual(model.notificationStatus, result == .authorized ? "permission.allowed" : "permission.denied")
                XCTAssertEqual(model.notificationActionTitle, "general.notification_settings")
            }
        }
    }
    func testDecidedPermissionsOpenSettingsWithoutReRequesting() async {
        for status: UNAuthorizationStatus in [.authorized, .provisional, .denied] {
            let fake = FakeSystem(); fake.authorization = status
            await withModel(fake) { model in
                model.requestNotifications(); await flushCallbacks()
                XCTAssertEqual(fake.requestCount, 0)
                XCTAssertEqual(fake.settingsCount, 1)
            }
        }
    }
    func testActionRechecksPermissionAndReturningRefreshesBothStatuses() async {
        let fake = FakeSystem()
        await withModel(fake) { model in
            fake.authorization = .denied
            model.requestNotifications(); await flushCallbacks()
            XCTAssertEqual(fake.requestCount, 0)
            XCTAssertEqual(fake.settingsCount, 1)
            fake.authorization = .authorized; fake.login = .enabled
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
            await flushCallbacks()
            XCTAssertEqual(model.notificationStatus, "permission.allowed")
            XCTAssertTrue(model.launchAtLogin)
            XCTAssertFalse(model.loginNeedsApproval)
        }
    }
    func testPermissionAndSettingsOpenFailuresAreVisible() async {
        let fake = FakeSystem(); fake.requestError = NSError(domain: "test", code: 1)
        await withModel(fake) { model in
            model.requestNotifications(); await flushCallbacks()
            XCTAssertEqual(model.errorMessage, L10n.text("error.notification"))
            XCTAssertTrue(model.canManageNotifications)
            model.dismissError(); fake.authorization = .denied; fake.opensSettings = false
            model.requestNotifications(); await flushCallbacks()
            XCTAssertEqual(model.errorMessage, L10n.text("error.notification_settings"))
        }
    }
    func testPendingLoginRemainsEnabledAndCanBeCancelled() async {
        let fake = FakeSystem()
        await withModel(fake) { model in
            model.setLogin(true)
            XCTAssertTrue(model.launchAtLogin); XCTAssertTrue(model.loginNeedsApproval)
            XCTAssertEqual(fake.registerCount, 1)
            model.openLoginSettings(); XCTAssertEqual(fake.loginSettingsCount, 1)
            model.setLogin(false)
            XCTAssertEqual(fake.unregisterCount, 1)
            XCTAssertFalse(model.launchAtLogin); XCTAssertFalse(model.loginNeedsApproval)
            fake.login = .requiresApproval; model.refreshLogin()
            XCTAssertTrue(model.launchAtLogin); XCTAssertTrue(model.loginNeedsApproval)
            fake.loginError = NSError(domain: "test", code: 2)
            model.setLogin(false)
            XCTAssertNotNil(model.errorMessage)
            XCTAssertTrue(model.launchAtLogin); XCTAssertTrue(model.loginNeedsApproval)
        }
    }
    func testDelegateIsRetainedAndPrewarningIsPresentedInForeground() async {
        let fake = FakeSystem(); fake.authorization = .authorized
        await withModel(fake) { model in
            XCTAssertNotNil(fake.delegate)
            var fallbackCount = 0
            model.notifyWarning(.short) { fallbackCount += 1 }
            await flushCallbacks()
            XCTAssertEqual(fake.requests.count, 1)
            XCTAssertEqual(fake.requests.first?.identifier, AppIdentity.identifier("prewarning"))
            XCTAssertEqual(ReminderNotificationDelegate.presentationOptions(for: fake.requests[0].identifier), [.banner, .list])
            XCTAssertEqual(ReminderNotificationDelegate.presentationOptions(for: "unrelated"), [])
            XCTAssertNil(fake.requests[0].content.sound)
            XCTAssertEqual(fallbackCount, 0)
            fake.deliveryError = NSError(domain: "test", code: 3)
            model.notifyWarning(.short) { fallbackCount += 1 }
            await flushCallbacks()
            XCTAssertEqual(fallbackCount, 1)
        }
        XCTAssertNil(fake.delegate)
    }
    func testDeniedAndNonAppExecutionUseFallbackWithoutSystemCalls() async {
        for available in [false, true] {
            let fake = FakeSystem(); fake.available = available; fake.authorization = .denied
            await withModel(fake) { model in
                var fallbackCount = 0
                model.notifyWarning(.short) { fallbackCount += 1 }
                XCTAssertEqual(fallbackCount, 1); XCTAssertTrue(fake.requests.isEmpty)
                if !available {
                    XCTAssertNil(fake.delegate)
                    XCTAssertEqual(model.notificationStatus, "permission.bundle")
                    XCTAssertFalse(model.canManageNotifications)
                    model.requestNotifications(); await flushCallbacks()
                    XCTAssertEqual(fake.requestCount, 0); XCTAssertEqual(fake.settingsCount, 0)
                }
            }
        }
    }
}
