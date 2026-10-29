import AppKit
import Combine
import TickRestCore

/// Owns the main application's half of the helper handoff. The helper survives replacement.
final class HomebrewUpgradeCoordinator: ObservableObject {
    @Published private(set) var state: UpdateJobState?
    @Published private(set) var errorMessage: String?
    var isResting: () -> Bool = { false }
    var prepareForInstallation: () throws -> Void = { throw HomebrewUpgradeFailure.parentGone }
    var quitForInstallation: () -> Void = {}
    private var store: UpdateJobStore?
    private var observer: AnyCancellable?
    private var launched: NSRunningApplication?
    private var handoffApproved = false
    private var askingToQuit = false
    private var automatic = false
    private var startedAt = Date()
    private var attempts = Set<String>()
    var isActive: Bool { state.map { !$0.phase.terminal } ?? false }
    var canCancel: Bool { state?.phase.canCancel == true && !handoffApproved }

    @MainActor func start(update: HomebrewUpdateManifest, automatic: Bool = false) {
        guard !isActive else { return }
        let info = Bundle.main.infoDictionary ?? [:]
        let app = Bundle.main.bundleURL
        let architecture = info["AppBuildArchitecture"] as? String ?? "unknown"
        guard app.pathExtension == "app", ["arm64", "x86_64", "universal"].contains(architecture) else {
            errorMessage = HomebrewUpgradeFailure.notManaged.errorDescription; return
        }
        guard !automatic || attempts.insert(update.release.identifier).inserted else { return }
        errorMessage = nil; self.automatic = automatic; handoffApproved = false; startedAt = Date()
        launched = nil
        store = nil
        state = UpdateJobState(.preparing)
        // The helper resolves the matching Homebrew before any update command is permitted.
        let brew = HomebrewInstallation.brewCandidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
        guard let brew else { fail(.homebrewMissing); return }
        let installation = HomebrewInstallation(brew: brew, channel: HomebrewUpdateConfiguration.channel, app: app,
                                                architecture: architecture,
                                                current: UpdateRelease(version: AppBuildInfo.current.version,
                                                                       build: AppBuildInfo.current.buildNumber))
        let job = UpdateJob(installation: installation, required: update.release, parentPID: ProcessInfo.processInfo.processIdentifier,
                            language: L10n.resolvedLanguage, automatic: automatic)
        do {
            let store = try UpdateJobStore.create(job)
            self.store = store
            let source = app.appendingPathComponent("Contents/Helpers/Tick Rest Updater.app")
            guard FileManager.default.fileExists(atPath: source.path) else { throw HomebrewUpgradeFailure.helperMissing }
            let helper = store.file("Tick Rest Updater.app")
            try FileManager.default.copyItem(at: source, to: helper)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.arguments = ["--update-job", store.directory.path]
            configuration.createsNewApplicationInstance = true
            configuration.activates = !automatic
            NSWorkspace.shared.openApplication(at: helper, configuration: configuration) { [weak self] running, error in
                Task { @MainActor [weak self] in
                    guard let self, self.store?.directory == store.directory else { return }
                    if error != nil || running == nil { self.fail(.launch); return }
                    self.launched = running
                }
            }
            observer?.cancel()
            observer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect().sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.poll() }
            }
        } catch { fail(error as? HomebrewUpgradeFailure ?? .helperMissing) }
    }

    @MainActor func cancel() {
        guard canCancel else { return }
        try? store?.signal("cancel.json")
    }

    @MainActor func cancelAutomatic() { if automatic { cancel() } }

    @MainActor func showProgress() {
        guard isActive, let store else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: store.file("Tick Rest Updater.app"), configuration: configuration)
    }

    func dismissError() { errorMessage = nil }

    @MainActor private func poll() {
        guard let store else { return }
        if let next = store.state, next != state { state = next }
        if state?.phase == .waiting, !handoffApproved, !askingToQuit, !store.hasSignal("cancel.json") {
            // Automatic updates wait until the rest finishes. Manual updates ask before interrupting it.
            if isResting() {
                guard !automatic else { return }
                let alert = NSAlert()
                askingToQuit = true
                defer { askingToQuit = false }
                alert.messageText = L10n.text("update.rest_title")
                alert.informativeText = L10n.text("update.rest_body")
                alert.addButton(withTitle: L10n.text("update.install_restart"))
                alert.addButton(withTitle: L10n.text("update.remind_later"))
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() != .alertFirstButtonReturn { cancel(); return }
            }
            handoff(store)
        }
        if let next = state, next.phase.terminal {
            observer?.cancel(); observer = nil
            if let failure = next.failure, failure != .cancelled { errorMessage = failure.errorDescription }
        } else if launched?.isTerminated == true { fail(.launch) }
        else if launched == nil && Date().timeIntervalSince(startedAt) > 30 { fail(.launch) }
    }

    @MainActor func handoff(_ store: UpdateJobStore) {
        guard !handoffApproved, store.state?.phase == .waiting, !store.hasSignal("cancel.json") else { return }
        do { try prepareForInstallation() }
        catch {
            try? store.signal("cancel.json")
            fail(.save)
            return
        }
        do {
            try store.signal("approved.json")
            handoffApproved = true
            observer?.cancel(); observer = nil
            quitForInstallation()
        } catch {
            try? store.signal("cancel.json")
            fail(.permissions)
        }
    }

    /// Surface interrupted jobs once, and clean up old copied helpers without touching an active one.
    @MainActor func recoverPreviousJobs() {
        guard !isActive, let directories = try? FileManager.default.contentsOfDirectory(at: UpdateJobStore.root,
                                          includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        var recent: [(UpdateJobStore, UpdateJob)] = []
        for directory in directories where UUID(uuidString: directory.lastPathComponent) != nil {
            let store = UpdateJobStore(directory: directory)
            let helper = directory.appendingPathComponent("Tick Rest Updater.app").standardizedFileURL.resolvingSymlinksInPath()
            let running = NSWorkspace.shared.runningApplications.first { $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == helper }
            if let values = try? directory.resourceValues(forKeys: [.contentModificationDateKey]),
               let modified = values.contentModificationDate, Date().timeIntervalSince(modified) > 7 * 86400,
               running == nil {
                try? FileManager.default.removeItem(at: directory)
                continue
            }
            guard let job = try? store.validatedJob(),
                  job.installation.app.standardizedFileURL.resolvingSymlinksInPath() == Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath() else { continue }
            if let phase = store.state?.phase, !phase.terminal, running == nil {
                try? store.write(UpdateJobState(.failed, failure: .launch), named: "state.json")
            }
            recent.append((store, job))
        }
        guard let (store, job) = recent.max(by: { $0.1.created < $1.1.created }),
              let saved = store.state else { return }
        if saved.phase.terminal {
            if !store.hasSignal("reported.json"), let failure = saved.failure, failure != .cancelled {
                errorMessage = failure.errorDescription
                try? store.signal("reported.json")
            }
        } else {
            self.store = store; state = saved; startedAt = Date(); handoffApproved = true; automatic = job.automatic
            let helper = store.file("Tick Rest Updater.app").standardizedFileURL.resolvingSymlinksInPath()
            launched = NSWorkspace.shared.runningApplications.first { $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == helper }
            // Only the original app may approve a download. A replacement launch only observes completion.
            if saved.phase.canCancel, job.parentPID != ProcessInfo.processInfo.processIdentifier { try? store.signal("cancel.json") }
            observer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect().sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.poll() }
            }
        }
    }

    @MainActor private func fail(_ failure: HomebrewUpgradeFailure) {
        if !handoffApproved { try? store?.signal("cancel.json") }
        state = UpdateJobState(.failed, failure: failure)
        errorMessage = failure.errorDescription
        observer?.cancel(); observer = nil
    }

    /// Called by a newly launched app only after its single-instance lock and model are ready.
    @MainActor static func acknowledgeRelaunch(arguments: [String] = CommandLine.arguments) {
        guard let index = arguments.firstIndex(of: "--tickrest-update-job"), arguments.indices.contains(index + 1) else { return }
        let store = UpdateJobStore(directory: URL(fileURLWithPath: arguments[index + 1], isDirectory: true))
        guard let job = try? store.validatedJob(), store.state?.phase == .relaunching,
              job.installation.app.standardizedFileURL.resolvingSymlinksInPath() == Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath(),
              (try? HomebrewUpgradeEngine.verifyApplication(Bundle.main.bundleURL, required: job.required,
                                                            architecture: job.installation.architecture,
                                                            channel: job.installation.channel)) != nil else { return }
        try? store.signal("started.json")
    }
}
