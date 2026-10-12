// Compiled only by build-native-system-audit.sh into an isolated test .app.
// The production controller, views and window coordinator are copied verbatim.
import AppKit
import SwiftUI
import ServiceManagement
import UserNotifications
import TickRestCore

final class SystemAudit: NSObject, NSApplicationDelegate {
    var model: AppController!
    var coordinator: WindowCoordinator!
    var control: NSWindow!
    var observers: [NSObjectProtocol] = []
    var timer: Timer?
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.arguments.count > 1
        ? ProcessInfo.processInfo.arguments[1] : NSTemporaryDirectory() + "tickrest-system-audit")
    let permissionExpectation = ProcessInfo.processInfo.arguments.count > 2 ? ProcessInfo.processInfo.arguments[2] : "denied"
    var lastPermission = ""
    var permissionRequested = false
    var permissionChecked = false
    var scenario: String?
    var sleepAt: Date?
    var wakeAt: Date?
    var initialRecords: Set<UUID> = []
    var sleepUsage: Double = 0
    var restoreLogin = false

    func log(_ event: String, _ details: [String: Any] = [:]) {
        var row = details
        row["event"] = event; row["at"] = ISO8601DateFormatter().string(from: Date())
        row["bundle"] = Bundle.main.bundleIdentifier
        if let model {
            row["away"] = model.engine.away; row["resting"] = model.engine.isResting
            row["longElapsed"] = model.engine.longElapsed; row["shortElapsed"] = model.engine.shortElapsed
            row["panels"] = NSApp.windows.compactMap { $0 as? ReminderPanel }.filter(\.isVisible).count
            row["permission"] = model.notificationStatus
            row["loginStatus"] = SMAppService.mainApp.status.rawValue
            row["loginUI"] = model.launchAtLogin
            row["error"] = model.errorMessage ?? ""
        }
        guard let bytes = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
              let file = try? FileHandle(forWritingTo: root.appendingPathComponent("events.jsonl")) else { return }
        defer { try? file.close() }
        file.seekToEndOfFile(); file.write(bytes); file.write(Data([10])); file.synchronizeFile()
    }
    func check(_ name: String, _ passed: Bool, _ details: [String: Any] = [:]) {
        var row = details; row["name"] = name; row["passed"] = passed
        log("assertion", row)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: root.appendingPathComponent("events.jsonl").path) {
            FileManager.default.createFile(atPath: root.appendingPathComponent("events.jsonl").path, contents: nil)
        }
        let store = DataStore(url: root.appendingPathComponent("state.json"))
        var data = SavedData(); data.settings.detectIdle = false; data.settings.avoidFullscreen = false
        data.settings.prewarning = 0; data.settings.sound = false; data.settings.language = "zh-Hans"
        data.settings.onboardingComplete = true
        try! store.save(data)
        model = AppController(store: store); coordinator = WindowCoordinator(model: model)
        model.onEffects = { [weak self] effects in self?.coordinator.apply(effects) }
        model.begin()
        restoreLogin = SMAppService.mainApp.status == .enabled
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                if name == NSWorkspace.willSleepNotification {
                    self.sleepAt = Date(); self.sleepUsage = self.model.engine.longElapsed
                }
                if name == NSWorkspace.didWakeNotification { self.wakeAt = Date() }
                self.log(name.rawValue)
            })
        }
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            observers.append(DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name(name), object: nil, queue: .main) { [weak self] _ in self?.log(name) })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.logScreens("display-change") })
        control = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        control.title = "Tick Rest 实机测试（独立数据）"; control.isReleasedWhenClosed = false
        control.contentView = NSHostingView(rootView: AuditControls(audit: self, model: model))
        control.center(); control.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
        logScreens("ready")
    }
    func logScreens(_ event: String) {
        log(event, ["screens": NSScreen.screens.map { ["name": $0.localizedName, "frame": NSStringFromRect($0.frame), "scale": $0.backingScaleFactor] }])
    }
    func command(_ value: String) {
        log("command", ["value": value])
        switch value {
        case "request-notifications":
            permissionRequested = true; permissionChecked = false; model.dismissError(); model.requestNotifications()
        case "diagnose-notifications":
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [self] granted, error in
                DispatchQueue.main.async {
                    let diagnostic = error as NSError?
                    log("authorization-diagnostic", ["granted": granted, "domain": diagnostic?.domain ?? "",
                        "code": diagnostic?.code ?? 0, "description": diagnostic?.localizedDescription ?? ""])
                }
            }
        case "refresh-permissions": model.refreshNotificationStatus(); model.refreshLogin()
        case "diagnose-and-login": command("diagnose-notifications"); command("login-cycle")
        case "login-cycle":
            guard [.notRegistered, .notFound].contains(SMAppService.mainApp.status) else {
                log("blocked", ["name": "login-cycle", "reason": "Test identity must initially be unregistered"]); return
            }
            model.dismissError(); model.setLogin(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
                model.refreshLogin(); let status = SMAppService.mainApp.status
                check("login.register.enabled", status == .enabled, ["requiresApproval": status == .requiresApproval])
                check("login.ui.matches-system", model.launchAtLogin == (status == .enabled))
                model.setLogin(false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
                    model.refreshLogin(); check("login.unregister", SMAppService.mainApp.status == .notRegistered && !model.launchAtLogin)
                }
            }
        case "sleep-rest", "sleep-work":
            coordinator.hide(restoreFocus: false)
            if model.engine.reminder != nil { model.action { $0.skip(now: Date()) } }
            model.clearRecords(); model.resume()
            initialRecords = Set(model.saved.records.map(\.id)); scenario = value
            sleepAt = nil; wakeAt = nil
            if value == "sleep-rest" { model.action { $0.startNow(.long, now: Date()) } }
            log("sleep-armed", ["scenario": value, "target": model.engine.reminder?.target ?? 0])
        case "check-notifications": verifyWarning()
        case "hotplug-overlay":
            model.update { $0.style = .overlay; $0.displayScope = .all }
            model.action { $0.startNow(.long, now: Date()) }; logScreens("hotplug-armed")
        case "end", "skip": model.action { $0.skip(now: Date()) }
        case "stop": NSApp.terminate(nil)
        default: log("unknown-command", ["value": value])
        }
    }
    func verifyWarning() {
        let expectedAllowed = model.notificationStatus == "permission.allowed"
        var fallback = false
        model.notifyWarning(.short) { [self] in
            fallback = true; coordinator.apply([.warning(.short)]); log("notification-fallback")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
            check("notification.fallback", fallback == !expectedAllowed)
            UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
                DispatchQueue.main.async { [self] in
                    let matching = notifications.filter { $0.request.identifier == AppIdentity.identifier("prewarning") }
                    log("notifications-delivered", ["count": matching.count])
                    if expectedAllowed { check("notification.delivered", !matching.isEmpty) }
                    model.removeNotifications(); coordinator.hide(restoreFocus: false)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        UNUserNotificationCenter.current().getDeliveredNotifications { remaining in
                            DispatchQueue.main.async {
                                self.check("notification.cleanup", !remaining.contains { $0.request.identifier == AppIdentity.identifier("prewarning") })
                            }
                        }
                    }
                }
            }
        }
    }
    func poll() {
        let commandURL = root.appendingPathComponent("command.txt")
        if let data = try? String(contentsOf: commandURL, encoding: .utf8) {
            try? FileManager.default.removeItem(at: commandURL)
            command(data.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if model.notificationStatus != lastPermission {
            lastPermission = model.notificationStatus; log("permission-change")
        }
        if permissionRequested && !permissionChecked && ["permission.allowed", "permission.denied"].contains(model.notificationStatus) {
            permissionChecked = true
            if model.errorMessage != nil {
                log("blocked", ["name": "notification.authorization.\(permissionExpectation)",
                    "reason": "Authorization API returned an error; denied state is not evidence of the user's refusal"])
            } else {
                check("notification.authorization.\(permissionExpectation)", model.notificationStatus == "permission.\(permissionExpectation)")
            }
            verifyWarning()
        }
        if let scenario, let sleepAt, let wakeAt, Date().timeIntervalSince(wakeAt) >= 3, !model.engine.away {
            let records = model.saved.records.filter { !initialRecords.contains($0.id) }
            let interrupted = records.filter { $0.outcome == .interrupted }
            let natural = records.filter { $0.outcome == .natural }
            let completed = records.filter { $0.outcome == .completed }
            let seconds = wakeAt.timeIntervalSince(sleepAt)
            check("\(scenario).real-power-events", seconds >= 30, ["sleepSeconds": seconds])
            check("\(scenario).away-cleared", !model.engine.away)
            check("\(scenario).interrupt-once", interrupted.count == (scenario == "sleep-rest" ? 1 : 0), ["count": interrupted.count])
            check("\(scenario).natural-once", natural.count == 1, ["count": natural.count, "seconds": natural.map(\.seconds).reduce(0, +)])
            check("\(scenario).no-false-completion", completed.isEmpty)
            check("\(scenario).sleep-not-charged", model.engine.longElapsed <= sleepUsage + 10,
                  ["beforeSleepUsage": sleepUsage, "afterWakeUsage": model.engine.longElapsed])
            log("sleep-result", ["scenario": scenario]); self.scenario = nil
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate(); coordinator.hide(restoreFocus: false); model.persist(); model.removeNotifications()
        if !restoreLogin && [.enabled, .requiresApproval].contains(SMAppService.mainApp.status) { model.setLogin(false) }
        log("stopped")
    }
}

struct AuditControls: View {
    let audit: SystemAudit
    @ObservedObject var model: AppController
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Tick Rest 实机测试").font(.title2)
            Text("调用正式 AppController 和 WindowCoordinator；设置及统计写入独立测试目录。")
            Text("通知：\(L10n.text(model.notificationStatus))　登录启动：\(model.launchAtLogin ? "已开启" : "未开启")")
            HStack {
                Button("请求通知权限") { audit.command("request-notifications") }
                Button("刷新权限状态") { audit.command("refresh-permissions") }
                Button("测试登录启动开关") { audit.command("login-cycle") }
            }
            Divider()
            Text("选择睡眠场景后，从苹果菜单选择睡眠。等待至少 60 秒，手动唤醒并解锁。")
            HStack {
                Button("准备休息中睡眠") { audit.command("sleep-rest") }
                Button("准备工作中睡眠") { audit.command("sleep-work") }
            }
            HStack {
                Button("准备双屏插拔遮罩") { audit.command("hotplug-overlay") }
                Button("关闭当前提醒") { audit.command("end") }
                Button("结束测试") { audit.command("stop") }
            }
            if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
            Text("证据目录：\(audit.root.path)").font(.caption).textSelection(.enabled)
        }.padding(24).frame(width: 592)
    }
}

let app = NSApplication.shared
let delegate = SystemAudit()
app.delegate = delegate; app.setActivationPolicy(.regular); app.run()
