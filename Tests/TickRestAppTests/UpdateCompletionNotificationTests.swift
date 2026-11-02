import Foundation
import UserNotifications
import XCTest
import TickRestCore
@testable import TickRestApp

@MainActor final class UpdateCompletionNotificationTests: XCTestCase {
    private final class Notifications {
        var status: UNAuthorizationStatus = .authorized
        var available = true
        var permissionRequests = 0
        var requests: [UNNotificationRequest] = []
        var error: Error?
        var access: SystemAccess {
            var access = SystemAccess.live
            access.notificationsAvailable = available
            access.notificationStatus = { $0(self.status) }
            access.requestNotifications = { self.permissionRequests += 1; $0(nil) }
            access.addNotification = { self.requests.append($0); $1(self.error) }
            return access
        }
    }

    private struct Fixture {
        let root: URL
        let app: URL
        let store: UpdateJobStore
        func writeApp(version: String = "1.0.6", channel: String = "dev", architecture: String = "universal") throws {
            let contents = app.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
            let info = ["CFBundleIdentifier": AppIdentity.bundleIdentifier, "CFBundleExecutable": "Tick Rest",
                        "CFBundleShortVersionString": version, "CFBundleVersion": "6",
                        "AppDistributionChannel": channel, "AppBuildArchitecture": architecture]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            let executable = contents.appendingPathComponent("MacOS/Tick Rest")
            try Data("fixture".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        @MainActor func notifier(_ fake: Notifications) -> UpdateCompletionNotification {
            UpdateCompletionNotification(system: fake.access, app: app, jobsRoot: root.appendingPathComponent("jobs"))
        }
    }

    private func withJob(phase: UpdateJobState.Phase = .completed, automatic: Bool = false,
                         _ body: (Fixture, Notifications) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("update-notification-\(UUID())")
        let app = root.appendingPathComponent("Tick Rest.app")
        let installation = HomebrewInstallation(brew: URL(fileURLWithPath: "/usr/local/bin/brew"), channel: .dev,
            app: app, architecture: "universal", current: UpdateRelease(version: "1.0.4", build: "4"))
        let job = UpdateJob(installation: installation, required: UpdateRelease(version: "1.0.5", build: "5"),
            parentPID: ProcessInfo.processInfo.processIdentifier, language: "en", automatic: automatic)
        let store = try UpdateJobStore.create(job, root: root.appendingPathComponent("jobs"))
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = Fixture(root: root, app: app, store: store)
        try fixture.writeApp()
        try store.signal("approved.json"); try store.signal("started.json")
        try store.write(UpdateJobState(phase), named: "state.json")
        try await body(fixture, Notifications())
    }

    func testManualAndAutomaticUpdatesNotifyOnceWithActualInstalledVersion() async throws {
        for automatic in [false, true] {
            try await withJob(automatic: automatic) { fixture, fake in
                await fixture.notifier(fake).notifyWhenCompleted(fixture.store)
                // A fresh notifier must still recognize that this job was already handled.
                await fixture.notifier(fake).notifyWhenCompleted(fixture.store)
                let request = try XCTUnwrap(fake.requests.first)
                XCTAssertEqual(fake.requests.count, 1)
                XCTAssertEqual(request.identifier, UpdateCompletionNotification.identifier)
                XCTAssertTrue(request.content.body.contains("1.0.6"), "The tap can install a newer version than the original offer")
                XCTAssertFalse(request.content.body.contains("{appName}"))
                XCTAssertNil(request.content.sound)
                XCTAssertNil(request.trigger)
                XCTAssertEqual(fake.permissionRequests, 0)
                XCTAssertTrue(fixture.store.hasSignal(UpdateCompletionNotification.handledSignal))
            }
        }
    }

    func testRelaunchAcknowledgementAloneDoesNotNotifyUntilHelperCompletes() async throws {
        try await withJob(phase: .relaunching) { fixture, fake in
            let task = Task { await fixture.notifier(fake).notifyWhenCompleted(fixture.store) }
            try await Task.sleep(nanoseconds: 20_000_000)
            XCTAssertTrue(fake.requests.isEmpty)
            try fixture.store.write(UpdateJobState(.completed), named: "state.json")
            await task.value
            XCTAssertEqual(fake.requests.count, 1)
        }
    }

    func testFailureCancellationAndRelaunchTimeoutNeverReportSuccess() async throws {
        for phase: UpdateJobState.Phase in [.failed, .cancelled, .installing, .verifying, .relaunching] {
            try await withJob(phase: phase) { fixture, fake in
                await fixture.notifier(fake).notifyWhenCompleted(fixture.store, timeout: 0)
                XCTAssertTrue(fake.requests.isEmpty)
                XCTAssertFalse(fixture.store.hasSignal(UpdateCompletionNotification.handledSignal))
            }
        }
    }

    func testDeniedUndecidedAndUnavailableNotificationsNeverRequestPermission() async throws {
        for status: UNAuthorizationStatus in [.denied, .notDetermined, .authorized] {
            try await withJob { fixture, fake in
                fake.status = status
                fake.available = status != .authorized
                await fixture.notifier(fake).notifyWhenCompleted(fixture.store)
                XCTAssertTrue(fake.requests.isEmpty)
                XCTAssertEqual(fake.permissionRequests, 0)
                XCTAssertEqual(fixture.store.state?.phase, .completed)
                XCTAssertTrue(fixture.store.hasSignal(UpdateCompletionNotification.handledSignal))
                fake.status = .authorized; fake.available = true
                await fixture.notifier(fake).notifyWhenCompleted(fixture.store)
                XCTAssertTrue(fake.requests.isEmpty, "Do not send an old notification after permission changes")
            }
        }
    }

    func testProvisionalPermissionAndForegroundPresentation() async throws {
        try await withJob { fixture, fake in
            fake.status = .provisional
            await fixture.notifier(fake).notifyWhenCompleted(fixture.store)
            XCTAssertEqual(fake.requests.count, 1)
            XCTAssertEqual(ReminderNotificationDelegate.presentationOptions(for: UpdateCompletionNotification.identifier), [.banner, .list])
            XCTAssertEqual(ReminderNotificationDelegate.presentationOptions(for: "unrelated"), [])
        }
    }

    func testOnlyVerifiedReplacementAppMayNotify() async throws {
        try await withJob { fixture, fake in
            let copied = UpdateCompletionNotification(system: fake.access, app: fixture.root.appendingPathComponent("copy.app"),
                jobsRoot: fixture.root.appendingPathComponent("jobs"))
            await copied.notifyWhenCompleted(fixture.store)
            for (version, channel, architecture) in [("1.0.4", "dev", "universal"),
                ("1.0.6", "stable", "universal"), ("1.0.6", "dev", "arm64")] {
                try fixture.writeApp(version: version, channel: channel, architecture: architecture)
                await fixture.notifier(fake).notifyWhenCompleted(fixture.store)
            }
            XCTAssertTrue(fake.requests.isEmpty)
            XCTAssertFalse(fixture.store.hasSignal(UpdateCompletionNotification.handledSignal))
        }
    }

    func testMissingHandoffSignalsNeverNotify() async throws {
        for signal in ["started.json", "approved.json"] {
            try await withJob { fixture, fake in
                try FileManager.default.removeItem(at: fixture.store.file(signal))
                await fixture.notifier(fake).notifyWhenCompleted(fixture.store)
                XCTAssertTrue(fake.requests.isEmpty)
            }
        }
    }

    func testStoppingAppCancelsPendingNotification() async throws {
        try await withJob(phase: .relaunching) { fixture, fake in
            let task = Task { await fixture.notifier(fake).notifyWhenCompleted(fixture.store) }
            try await Task.sleep(nanoseconds: 20_000_000)
            task.cancel()
            try fixture.store.write(UpdateJobState(.completed), named: "state.json")
            await task.value
            XCTAssertTrue(fake.requests.isEmpty)
        }
    }

    func testNotificationDeliveryFailureDoesNotChangeUpdateResultOrRetry() async throws {
        try await withJob { fixture, fake in
            fake.error = NSError(domain: "notifications", code: 1)
            await fixture.notifier(fake).notifyWhenCompleted(fixture.store)
            await fixture.notifier(fake).notifyWhenCompleted(fixture.store)
            XCTAssertEqual(fake.requests.count, 1)
            XCTAssertEqual(fixture.store.state?.phase, .completed)
        }
    }

    func testSuccessNotificationIsLocalizedInAllAppLanguages() async throws {
        let previous = L10n.language
        defer { L10n.language = previous }
        for language in ["en", "zh-Hans", "zh-Hant", "ja", "ko"] {
            L10n.language = language
            try await withJob { fixture, fake in
                await fixture.notifier(fake).notifyWhenCompleted(fixture.store)
                let request = try XCTUnwrap(fake.requests.first)
                XCTAssertNotEqual(request.content.title, "update.notification_title")
                XCTAssertTrue(request.content.body.contains("1.0.6"))
                XCTAssertTrue(request.content.body.contains(AppIdentity.name))
                XCTAssertFalse(request.content.body.contains("{appName}"))
            }
        }
    }
}
