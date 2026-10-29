import Foundation
import XCTest
@testable import TickRestCore

final class HomebrewUpgradeTests: XCTestCase {
    private var root: URL!
    private var installation: HomebrewInstallation!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tickrest-upgrade-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        installation = HomebrewInstallation(brew: URL(fileURLWithPath: "/usr/local/bin/brew"), channel: .dev,
                                            app: root.appendingPathComponent("Apps with spaces/Tick Rest.app"),
                                            architecture: "arm64", current: UpdateRelease(version: "1.0.0", build: "1"))
        try createApp(version: "1.0.0", build: "1")
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testBuildOrderingAndRequiredVersion() throws {
        XCTAssertEqual(UpdateRelease(version: "1"), UpdateRelease(version: "1.0.0", build: "0"))
        XCTAssertLessThan(UpdateRelease(version: "1.0.0", build: "9"), UpdateRelease(version: "1.0.0", build: "10"))
        XCTAssertTrue(UpdateRelease(version: "1.0.0", build: "10").meets(UpdateRelease(version: "1.0.0")))
        XCTAssertFalse(UpdateRelease(version: "1.0.0").meets(UpdateRelease(version: "1.0.0", build: "2")))
        XCTAssertNil(UpdateRelease(caskVersion: "latest"))
        XCTAssertNil(UpdateRelease(caskVersion: "1.0.0,"))
        XCTAssertNil(UpdateRelease(caskVersion: "1.0.0,1,2"))
    }

    func testCaskMustOwnActualRunningAppAndUseOwnReleaseRepository() throws {
        let good = try fixture()
        XCTAssertNoThrow(try snapshot(good))
        for (key, value) in [("tap", "other/tap"), ("token", "other"), ("installed", ""),
                              ("url", "https://github.com/other/repo/releases/download/v1/a.zip"),
                              ("url", "http://github.com/fthux/tick-rest-macos-dev/releases/download/v1/a.zip"),
                              ("sha256", "no_check")] {
            var cask = good
            cask[key] = value
            XCTAssertThrowsError(try snapshot(cask), key)
        }
        var foreign = good
        foreign["artifacts"] = [["app": ["Tick Rest-arm64.app", ["target": "Tick Rest.app"]],
                                  "target": "/Applications/Tick Rest.app"]]
        XCTAssertThrowsError(try snapshot(foreign), "A copied app must not upgrade the managed original")
        foreign["artifacts"] = [["app": ["Tick Rest-arm64.app", ["target": "Tick Rest.app"]]]]
        XCTAssertThrowsError(try snapshot(foreign), "Missing ownership data must fail closed")
    }

    @MainActor func testPrepareDownloadsWhileInstallIsAnExplicitSeparateOperation() async throws {
        let runner = FakeBrewRunner(cask: try fixture())
        let engine = HomebrewUpgradeEngine(runner: runner)
        var phases: [String] = []
        let prepared = try await engine.prepare(installation, required: UpdateRelease(version: "1.1.0", build: "2"), stage: { phases.append($0) })
        XCTAssertEqual(phases, ["update.stage.preparing", "update.stage.refreshing", "update.stage.downloading"])
        XCTAssertTrue(runner.commands.contains { $0.first == "fetch" })
        XCTAssertFalse(runner.commands.contains { $0.first == "upgrade" })
        try createApp(version: "1.1.0", build: "2")
        runner.onUpgrade = { runner.cask["installed"] = "1.1.0,2" }
        try await engine.install(installation, prepared: prepared, stage: { phases.append($0) })
        let upgrade = try XCTUnwrap(runner.commands.first { $0.first == "upgrade" })
        XCTAssertEqual(upgrade, ["upgrade", "--cask", "fthux/tap/tickrest-dev", "--appdir=" + installation.appDirectory.path])
        XCTAssertEqual(phases.suffix(2), ["update.stage.installing", "update.stage.verifying"])
        for environment in runner.environments {
            XCTAssertEqual(environment["HOMEBREW_TICKREST_DEV_ARCH"], "arm64")
            XCTAssertEqual(environment["HOMEBREW_NO_AUTO_UPDATE"], "1")
            XCTAssertEqual(environment["HOMEBREW_NO_INSTALL_CLEANUP"], "1")
        }
    }

    @MainActor func testStaleTapAndDownloadFailureNeverInstall() async throws {
        let stale = FakeBrewRunner(cask: try fixture(version: "1.0.0,1"))
        do {
            _ = try await HomebrewUpgradeEngine(runner: stale).prepare(installation, required: UpdateRelease(version: "1.1.0"), stage: { _ in })
            XCTFail("Stale tap must be rejected")
        } catch { XCTAssertEqual(error as? HomebrewUpgradeFailure, .notReady) }
        XCTAssertFalse(stale.commands.contains { ["fetch", "upgrade"].contains($0.first ?? "") })
        let failed = FakeBrewRunner(cask: try fixture()); failed.failCommand = "fetch"
        do {
            _ = try await HomebrewUpgradeEngine(runner: failed).prepare(installation, required: UpdateRelease(version: "1.1.0"), stage: { _ in })
            XCTFail("Failed download must be rejected")
        } catch { XCTAssertEqual(error as? HomebrewUpgradeFailure, .command) }
        XCTAssertFalse(failed.commands.contains { $0.first == "upgrade" })
    }

    @MainActor func testChangedMetadataAfterDownloadOrBeforeInstallIsRejected() async throws {
        let runner = FakeBrewRunner(cask: try fixture())
        runner.onFetch = { runner.cask["sha256"] = String(repeating: "b", count: 64) }
        do {
            _ = try await HomebrewUpgradeEngine(runner: runner).prepare(installation, required: UpdateRelease(version: "1.1.0"), stage: { _ in })
            XCTFail("Changed metadata must restart the download")
        } catch { XCTAssertEqual(error as? HomebrewUpgradeFailure, .metadataChanged) }
        runner.onFetch = nil
        let engine = HomebrewUpgradeEngine(runner: runner)
        let prepared = try await engine.prepare(installation, required: UpdateRelease(version: "1.1.0"), stage: { _ in })
        runner.cask["version"] = "1.2.0,3"
        do { try await engine.install(installation, prepared: prepared, stage: { _ in }); XCTFail("Changed target must not install") }
        catch { XCTAssertEqual(error as? HomebrewUpgradeFailure, .metadataChanged) }
        XCTAssertFalse(runner.commands.contains { $0.first == "upgrade" })
    }

    @MainActor func testSuccessExitCodeWithoutUpgradedReceiptIsNotSuccess() async throws {
        let runner = FakeBrewRunner(cask: try fixture()), engine = HomebrewUpgradeEngine(runner: runner)
        let prepared = try await engine.prepare(installation, required: UpdateRelease(version: "1.1.0"), stage: { _ in })
        do { try await engine.install(installation, prepared: prepared, stage: { _ in }); XCTFail("Old receipt must fail verification") }
        catch { XCTAssertEqual(error as? HomebrewUpgradeFailure, .verification) }
    }

    func testVerificationRejectsWrongChannelArchitectureAndOldBuild() throws {
        try createApp(version: "1.1.0", build: "2")
        XCTAssertNoThrow(try verify())
        try createApp(version: "1.1.0", build: "1")
        XCTAssertThrowsError(try verify())
        try createApp(version: "1.1.0", build: "2", channel: "stable")
        XCTAssertThrowsError(try verify())
        try createApp(version: "1.1.0", build: "2", architecture: "universal")
        XCTAssertThrowsError(try verify())
    }

    func testJobControlsArePrivateAndValidateLocationAndPayload() throws {
        let job = UpdateJob(installation: installation, required: UpdateRelease(version: "1.1.0", build: "2"),
                            parentPID: 1234, language: "en", automatic: false)
        let jobs = root.appendingPathComponent("jobs")
        let store = try UpdateJobStore.create(job, root: jobs)
        XCTAssertEqual(try store.validatedJob(root: jobs).id, job.id)
        XCTAssertThrowsError(try store.validatedJob())
        XCTAssertFalse(store.hasSignal("approved.json"))
        try store.signal("approved.json")
        XCTAssertTrue(store.hasSignal("approved.json"))
        let attributes = try FileManager.default.attributesOfItem(atPath: store.directory.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: store.directory.path)
        XCTAssertThrowsError(try store.validatedJob(root: jobs))
    }

    func testEnvironmentPreservesProxyButNotCommandOverrides() {
        let environment = installation.environment(base: ["HTTPS_PROXY": "http://localhost:1234", "HOME": root.path,
                                                           "HOMEBREW_CASK_OPTS": "--force", "BASH_ENV": "/tmp/untrusted",
                                                           "HOMEBREW_TICKREST_DEV_ARCH": "universal"])
        XCTAssertEqual(environment["HTTPS_PROXY"], "http://localhost:1234")
        XCTAssertNil(environment["HOMEBREW_CASK_OPTS"])
        XCTAssertNil(environment["BASH_ENV"])
        XCTAssertEqual(environment["HOMEBREW_TICKREST_DEV_ARCH"], "arm64")
    }

    func testProcessRunnerKeepsArgumentsLiteralAndSeparatesStderrFromJSON() async throws {
        let script = root.appendingPathComponent("fake brew")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$1\"\nprintf 'stderr message' >&2\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let runner = BrewProcessRunner()
        let literal = "$(touch /tmp/never-run-tickrest); `echo no` spaces"
        let result = try await runner.run(executable: script, arguments: [literal], environment: ["PATH": "/usr/bin:/bin"], timeout: 5)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(String(decoding: result.output, as: UTF8.self), literal + "\n")
    }

    func testProcessTimeoutAndCancellationAreReported() async throws {
        for cancelled in [false, true] {
            let runner = BrewProcessRunner()
            if cancelled { runner.cancel() }
            do {
                _ = try await runner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["3"], environment: [:], timeout: 0.1)
                XCTFail("Process must stop")
            } catch { XCTAssertEqual(error as? HomebrewUpgradeFailure, cancelled ? .cancelled : .timeout) }
        }
    }

    func testCancellationStopsDescendantsEvenWhenTheyIgnoreTermination() async throws {
        let script = root.appendingPathComponent("slow brew")
        let childPID = root.appendingPathComponent("child.pid")
        try Data("#!/bin/sh\ntrap '' TERM\n/bin/sleep 30 &\necho $! > \"$1\"\nwait\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let runner = BrewProcessRunner()
        let started = Date()
        let task = Task { try await runner.run(executable: script, arguments: [childPID.path], environment: [:], timeout: 10) }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: childPID.path) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let pid = try XCTUnwrap(Int32(try String(contentsOf: childPID, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled process must fail") }
        catch { XCTAssertEqual(error as? HomebrewUpgradeFailure, .cancelled) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
        // An orphan may briefly be a zombie until launchd reaps it; it must never still be running.
        let probe = Process(); probe.executableURL = URL(fileURLWithPath: "/bin/ps")
        probe.arguments = ["-o", "stat=", "-p", String(pid)]
        let pipe = Pipe(); probe.standardOutput = pipe
        try probe.run(); probe.waitUntilExit()
        let status = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(status.isEmpty || status.hasPrefix("Z"), status)
    }

    @MainActor func testVersionOnlyCaskReceiptSupportsBuildNumberInApp() async throws {
        var cask = try fixture(); cask["installed"] = "1.0.0"
        let runner = FakeBrewRunner(cask: cask)
        _ = try await HomebrewUpgradeEngine(runner: runner).prepare(installation,
            required: UpdateRelease(version: "1.1.0"), stage: { _ in })
        XCTAssertTrue(runner.commands.contains { $0.first == "fetch" })
    }

    @MainActor func testStateWriteFailureBeforeInstallNeverRunsUpgrade() async throws {
        let runner = FakeBrewRunner(cask: try fixture()), engine = HomebrewUpgradeEngine(runner: runner)
        let prepared = try await engine.prepare(installation, required: UpdateRelease(version: "1.1.0"), stage: { _ in })
        do {
            try await engine.install(installation, prepared: prepared, stage: { _ in throw HomebrewUpgradeFailure.permissions })
            XCTFail("An unreadable handoff must stop before installation")
        } catch { XCTAssertEqual(error as? HomebrewUpgradeFailure, .permissions) }
        XCTAssertFalse(runner.commands.contains { $0.first == "upgrade" })
    }

    private func fixture(version: String = "1.1.0,2") throws -> [String: Any] {
        ["token": "tickrest-dev", "tap": "fthux/tap", "version": version, "installed": "1.0.0,1",
         "url": "https://github.com/fthux/tick-rest-macos-dev/releases/download/v1.1.0/a.zip",
         "sha256": String(repeating: "a", count: 64),
         "artifacts": [["app": ["Tick Rest-arm64.app", ["target": "Tick Rest.app"]], "target": installation.app.path]]]
    }
    private func snapshot(_ cask: [String: Any]) throws -> BrewCaskSnapshot {
        try BrewCaskSnapshot(data: JSONSerialization.data(withJSONObject: ["casks": [cask]]), channel: .dev,
                             appURL: installation.app, appDirectory: installation.appDirectory)
    }
    private func createApp(version: String, build: String, channel: String = "dev", architecture: String = "arm64") throws {
        let contents = installation.app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": AppIdentity.bundleIdentifier, "CFBundleExecutable": "Tick Rest",
                    "CFBundleShortVersionString": version, "CFBundleVersion": build,
                    "AppDistributionChannel": channel, "AppBuildArchitecture": architecture]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        let executable = contents.appendingPathComponent("MacOS/Tick Rest")
        try Data("fixture".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }
    private func verify() throws {
        try HomebrewUpgradeEngine.verifyApplication(installation.app, required: UpdateRelease(version: "1.1.0", build: "2"), architecture: "arm64", channel: .dev)
    }
}

private final class FakeBrewRunner: BrewCommandRunning {
    var cask: [String: Any]
    var commands: [[String]] = []
    var environments: [[String: String]] = []
    var failCommand: String?
    var onUpgrade: (() -> Void)?
    var onFetch: (() -> Void)?
    init(cask: [String: Any]) { self.cask = cask }
    func cancel() {}
    func run(executable: URL, arguments: [String], environment: [String: String], timeout: TimeInterval) async throws -> BrewCommandResult {
        commands.append(arguments); environments.append(environment)
        if arguments.first == failCommand { return BrewCommandResult(status: 1) }
        if arguments.first == "upgrade" { onUpgrade?() }
        if arguments.first == "fetch" { onFetch?() }
        if arguments.first == "info" { return BrewCommandResult(status: 0, output: try JSONSerialization.data(withJSONObject: ["casks": [cask]])) }
        return BrewCommandResult(status: 0)
    }
}
