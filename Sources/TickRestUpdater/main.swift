import AppKit
import TickRestCore

@MainActor final class UpdaterDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private let heading = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let action = NSButton()
    private let logView = NSTextView()
    private var logScroll: NSScrollView!
    private var logText = ""
    private var store: UpdateJobStore?
    private var job: UpdateJob?
    private var parent: NSRunningApplication?
    private var state = UpdateJobState(.preparing)
    private let runner = BrewProcessRunner()
    private var task: Task<Void, Never>?
    private var timer: Timer?
    private var lockFD: Int32 = -1
    private var instanceFD: Int32 = -1

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--update-job" else {
                throw HomebrewUpgradeFailure.invalidJob
            }
            let store = UpdateJobStore(directory: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true))
            let job = try store.validatedJob()
            self.store = store; self.job = job
            L10n.language = job.language
            guard !store.hasSignal("cancel.json") else { throw HomebrewUpgradeFailure.cancelled }
            parent = NSRunningApplication(processIdentifier: job.parentPID)
            guard let parent, !parent.isTerminated,
                  parent.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == job.installation.app.standardizedFileURL.resolvingSymlinksInPath() else {
                throw HomebrewUpgradeFailure.parentGone
            }
            lockFD = open(UpdateJobStore.root.appendingPathComponent("update.lock").path, O_CREAT | O_RDWR, 0o600)
            guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw HomebrewUpgradeFailure.ambiguous }
            makeWindow()
            runner.onOutput = { [weak self] text in
                DispatchQueue.main.async { self?.appendLog(text) }
            }
            timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.state.phase.canCancel, self.store?.hasSignal("cancel.json") == true else { return }
                    self.runner.cancel(); self.task?.cancel()
                }
            }
            task = Task { await run(job) }
        } catch { finish(error) }
    }

    private func run(_ job: UpdateJob) async {
        do {
            let engine = HomebrewUpgradeEngine(runner: runner)
            var matches: [HomebrewInstallation] = []
            for brew in HomebrewInstallation.brewCandidates where FileManager.default.isExecutableFile(atPath: brew.path) {
                let candidate = HomebrewInstallation(brew: brew, channel: job.installation.channel, app: job.installation.app,
                                                     architecture: job.installation.architecture, current: job.installation.current)
                do { _ = try await engine.snapshot(candidate); matches.append(candidate) }
                catch { try Task.checkCancellation() }
            }
            guard matches.count == 1, let installation = matches.first else {
                throw matches.isEmpty ? HomebrewUpgradeFailure.notManaged : HomebrewUpgradeFailure.ambiguous
            }
            let prepared = try await engine.prepare(installation, required: job.required, stage: stage)
            try Task.checkCancellation()
            guard parent?.isTerminated == false else { throw HomebrewUpgradeFailure.parentGone }
            guard setState(UpdateJobState(.waiting)) else { throw HomebrewUpgradeFailure.permissions }
            // A running parent must explicitly approve installation after saving its state.
            let end = Date().addingTimeInterval(1800)
            while store?.hasSignal("approved.json") != true {
                try Task.checkCancellation()
                guard parent?.isTerminated == false else { throw HomebrewUpgradeFailure.parentGone }
                guard Date() < end else { throw HomebrewUpgradeFailure.timeout }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            let exitDeadline = Date().addingTimeInterval(30)
            while parent?.isTerminated == false {
                try Task.checkCancellation()
                guard Date() < exitDeadline else { throw HomebrewUpgradeFailure.timeout }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            try Task.checkCancellation()
            // Close the gap in which another launch could start a scheduler during replacement.
            instanceFD = open(UpdateJobStore.root.deletingLastPathComponent().appendingPathComponent("instance.lock").path,
                              O_CREAT | O_RDWR, 0o600)
            guard instanceFD >= 0, flock(instanceFD, LOCK_EX | LOCK_NB) == 0 else { throw HomebrewUpgradeFailure.ambiguous }
            try await engine.install(installation, prepared: prepared, stage: stage)
            // Verify Apple/ad-hoc code integrity before asking LaunchServices to execute it.
            let signed = try await runner.run(executable: URL(fileURLWithPath: "/usr/bin/codesign"),
                                               arguments: ["--verify", "--deep", "--strict", installation.app.path],
                                               environment: installation.environment(), timeout: 30)
            guard signed.status == 0 else { throw HomebrewUpgradeFailure.verification }
            guard setState(UpdateJobState(.relaunching)) else { throw HomebrewUpgradeFailure.permissions }
            releaseInstanceLock()
            try await relaunch(installation.app, acknowledge: true)
            let launchDeadline = Date().addingTimeInterval(30)
            while store?.hasSignal("started.json") != true {
                guard Date() < launchDeadline else { throw HomebrewUpgradeFailure.launch }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            guard setState(UpdateJobState(.completed)) else { throw HomebrewUpgradeFailure.permissions }
            if job.automatic { NSApp.terminate(nil) }
        } catch { finish(error) }
    }

    private func stage(_ key: String) throws {
        if let name = key.components(separatedBy: ".").last, let phase = UpdateJobState.Phase(rawValue: name) {
            guard setState(UpdateJobState(phase)) else { throw HomebrewUpgradeFailure.permissions }
        }
    }

    @discardableResult private func setState(_ value: UpdateJobState) -> Bool {
        state = value
        var written = true
        do { try store?.write(value, named: "state.json") }
        catch { written = false; appendLog("State write failed: \(error.localizedDescription)\n") }
        if value.phase.terminal {
            timer?.invalidate(); timer = nil
            releaseInstanceLock()
            if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD); lockFD = -1 }
        }
        guard window != nil else { return written }
        heading.stringValue = value.message
        detail.stringValue = value.phase == .waiting ? L10n.text("update.waiting_help") : L10n.text("update.progress_help")
        if value.phase.terminal { progress.stopAnimation(nil) } else { progress.startAnimation(nil) }
        action.title = L10n.text(value.phase.terminal ? "common.close" : "common.cancel")
        action.isEnabled = value.phase.canCancel || value.phase.terminal
        if value.phase == .failed { showWindow() }
        return written
    }

    private func releaseInstanceLock() {
        if instanceFD >= 0 { flock(instanceFD, LOCK_UN); close(instanceFD); instanceFD = -1 }
    }

    private func finish(_ error: Error) {
        let failure = error is CancellationError ? HomebrewUpgradeFailure.cancelled : (error as? HomebrewUpgradeFailure ?? .command)
        if window == nil { makeWindow() }
        appendLog(error.localizedDescription + "\n")
        setState(UpdateJobState(failure == .cancelled ? .cancelled : .failed, failure: failure))
        // Best effort only: never overwrite Homebrew's installation to simulate a rollback.
        if parent?.isTerminated == true, let job,
           (try? HomebrewUpgradeEngine.verifyApplication(job.installation.app, required: job.installation.current,
                                                         architecture: job.installation.architecture,
                                                         channel: job.installation.channel)) != nil {
            Task {
                let verifier = BrewProcessRunner()
                let signed = try? await verifier.run(executable: URL(fileURLWithPath: "/usr/bin/codesign"),
                    arguments: ["--verify", "--deep", "--strict", job.installation.app.path],
                    environment: job.installation.environment(), timeout: 30)
                if signed?.status == 0 { try? await relaunch(job.installation.app, acknowledge: false) }
            }
        }
    }

    private func relaunch(_ url: URL, acknowledge: Bool) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if acknowledge, let store { configuration.arguments = ["--tickrest-update-job", store.directory.path] }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { running, error in
                if let error { continuation.resume(throwing: error) }
                else if running != nil { continuation.resume() }
                else { continuation.resume(throwing: HomebrewUpgradeFailure.launch) }
            }
        }
    }

    private func makeWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 250),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = L10n.text("update.prompt_window_title")
        window.isReleasedWhenClosed = false; window.delegate = self
        let root = NSView(); window.contentView = root
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        heading.stringValue = state.message; heading.font = .boldSystemFont(ofSize: 16)
        detail.stringValue = L10n.text("update.progress_help"); detail.textColor = .secondaryLabelColor
        progress.style = .bar; progress.isIndeterminate = true; progress.startAnimation(nil)
        let details = NSButton(title: L10n.text("update.show_log"), target: self, action: #selector(toggleLog))
        details.bezelStyle = .rounded
        action.title = L10n.text("common.cancel"); action.bezelStyle = .rounded
        action.target = self; action.action = #selector(performAction)
        let buttons = NSStackView(views: [details, NSView(), action]); buttons.orientation = .horizontal
        let content = NSStackView(views: [heading, detail, progress, buttons])
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 18
        content.translatesAutoresizingMaskIntoConstraints = false
        logScroll = NSScrollView(); logScroll.hasVerticalScroller = true
        logView.isEditable = false; logView.isSelectable = true
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.isVerticallyResizable = true
        logView.autoresizingMask = [.width]; logView.textContainer?.widthTracksTextView = true
        logScroll.documentView = logView; logScroll.isHidden = true
        logScroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(icon); root.addSubview(content); root.addSubview(logScroll)
        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            icon.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            icon.widthAnchor.constraint(equalToConstant: 64), icon.heightAnchor.constraint(equalToConstant: 64),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            content.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            heading.widthAnchor.constraint(equalTo: content.widthAnchor), detail.widthAnchor.constraint(equalTo: content.widthAnchor),
            progress.widthAnchor.constraint(equalTo: content.widthAnchor), buttons.widthAnchor.constraint(equalTo: content.widthAnchor),
            logScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            logScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            logScroll.topAnchor.constraint(equalTo: root.topAnchor, constant: 230),
            logScroll.heightAnchor.constraint(equalToConstant: 230)
        ])
        window.center()
        if job?.automatic != true { showWindow() }
    }
    private func showWindow() { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if window != nil { showWindow() }
        return false
    }
    private func appendLog(_ text: String) {
        store?.appendLog(text)
        logText = String((logText + text).suffix(32 * 1024))
        logView.string = logText; logView.scrollToEndOfDocument(nil)
    }
    @objc private func toggleLog() {
        logScroll.isHidden.toggle()
        let height: CGFloat = logScroll.isHidden ? 250 : 490
        let frame = window.frame
        window.setFrame(NSRect(x: frame.minX, y: frame.maxY - height - 28, width: frame.width, height: height + 28), display: true, animate: true)
    }
    @objc private func performAction() {
        if state.phase.terminal { NSApp.terminate(nil) }
        else if state.phase.canCancel { runner.cancel(); task?.cancel() }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if state.phase.terminal { NSApp.terminate(nil); return true }
        if state.phase.canCancel { performAction() }
        return false
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if state.phase.terminal { return .terminateNow }
        if state.phase.canCancel { performAction() }
        return .terminateCancel
    }
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        releaseInstanceLock()
        if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD) }
    }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = UpdaterDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
}
