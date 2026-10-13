#!/usr/bin/env python3
"""Launch the real delegate in isolated .app processes and test its instance lock."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
AUDIT = ROOT / ".build/full-audit-20261014/launch"
PACKAGE = AUDIT / "package"
AUDIT.mkdir(parents=True, exist_ok=True)
for module in ("TickRestCore", "TickRestApp"):
    target = PACKAGE / "Sources" / module
    if target.exists():
        shutil.rmtree(target)
    shutil.copytree(ROOT / "Sources" / module, target)
identity_path = PACKAGE / "Sources/TickRestCore/Resources/AppIdentity.json"
identity = json.loads(identity_path.read_text())
identity["bundleIdentifier"] += ".launch-audit-20261014"
identity["dataDirectory"] = "TickRestLaunchAudit20261014"
identity_path.write_text(json.dumps(identity))
(PACKAGE / "Package.swift").write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "LaunchAudit", defaultLocalization: "en", platforms: [.macOS(.v13)],
 products: [.executable(name: "LaunchAudit", targets: ["TickRestApp"])],
 targets: [.target(name: "TickRestCore", resources: [.process("Resources")]),
 .executableTarget(name: "TickRestApp", dependencies: ["TickRestCore"])], swiftLanguageModes: [.v5])
''')
(PACKAGE / "Sources/TickRestApp/main.swift").write_text('''import AppKit
import TickRestCore
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
let token = CommandLine.arguments[2]
let store = DataStore(url: directory.appendingPathComponent("state.json"))
if !FileManager.default.fileExists(atPath: store.url.path) {
    var data = SavedData(); data.settings.onboardingComplete = true
    data.settings.detectIdle = false; data.settings.avoidFullscreen = false
    data.settings.sound = false; data.settings.language = "en"
    try store.save(data)
}
let app = NSApplication.shared
let delegate = AppDelegate(store: store, lockDirectory: directory.appendingPathComponent("lock"))
app.delegate = delegate; app.setActivationPolicy(.accessory)
func capture() {
    let fields = Mirror(reflecting: delegate).children
    let model = fields.first { $0.label == "model" }?.value as? AppController
    let status = fields.first { $0.label == "status" }?.value as? NSStatusItem
    let value: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
        "model": model != nil, "statusButton": status?.button != nil,
        "revision": model?.revision ?? -1,
        "settingsVisible": app.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) },
        "screens": NSScreen.screens.count]
    let bytes = try! JSONSerialization.data(withJSONObject: value)
    try! bytes.write(to: directory.appendingPathComponent(token + ".json"), options: .atomic)
}
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { capture() }
DispatchQueue.main.asyncAfter(deadline: .now() + 5) { capture(); app.terminate(nil) }
app.run()
''')
(AUDIT / "source-sha256.json").write_text(json.dumps({str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
    for p in (ROOT / "Sources").rglob("*") if p.is_file()}, indent=2))
env = dict(os.environ)
env.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
with (AUDIT / "build.log").open("w") as log:
    subprocess.run(["xcrun", "swift", "build", "--disable-sandbox", "--package-path", str(PACKAGE)],
                   env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
binary = Path(subprocess.check_output(["xcrun", "swift", "build", "--package-path", str(PACKAGE), "--show-bin-path"], env=env, text=True).strip())
app = AUDIT / "Launch Audit.app"
if app.exists():
    shutil.rmtree(app)
(app / "Contents/MacOS").mkdir(parents=True)
(app / "Contents/Resources").mkdir()
shutil.copy2(binary / "LaunchAudit", app / "Contents/MacOS/LaunchAudit")
shutil.copytree(binary / "LaunchAudit_TickRestCore.bundle", app / "Contents/Resources/LaunchAudit_TickRestCore.bundle")
(app / "Contents/Info.plist").write_bytes(plistlib.dumps(dict(
    CFBundleIdentifier=identity["bundleIdentifier"], CFBundleName="Launch Audit", CFBundleExecutable="LaunchAudit",
    CFBundlePackageType="APPL", CFBundleVersion="1", CFBundleShortVersionString="1.0", LSUIElement=True,
    LSMinimumSystemVersion="13.0", AppResourceBundle="LaunchAudit_TickRestCore")))
subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(app)], check=True, capture_output=True)
data = AUDIT / "isolated-data"
if data.exists():
    shutil.rmtree(data)
data.mkdir()
processes = []
logs = []
checks = {}

def launch(token):
    log = (AUDIT / (token + ".log")).open("w")
    logs.append(log)
    process = subprocess.Popen([str(app / "Contents/MacOS/LaunchAudit"), str(data), token], stdout=log, stderr=subprocess.STDOUT)
    processes.append(process)
    return process

try:
    first = launch("first")
    deadline = time.monotonic() + 20
    while not (data / "first.json").exists() and first.poll() is None and time.monotonic() < deadline:
        time.sleep(0.1)
    ready = json.loads((data / "first.json").read_text())
    checks["real_entry_initializes_model_and_status_item"] = ready["model"] and ready["statusButton"]
    second = launch("second")
    checks["duplicate_process_exits_without_scheduler"] = second.wait(timeout=10) == 0 and not (data / "second.json").exists()
    checks["first_process_stays_alive_after_duplicate_launch"] = first.poll() is None
    checks["first_process_exits_cleanly"] = first.wait(timeout=15) == 0
    final = json.loads((data / "first.json").read_text())
    checks["live_timer_advances_revision"] = final["revision"] > ready["revision"]
    checks["duplicate_launch_opens_first_instances_settings"] = final["settingsVisible"]
    checks["termination_saves_readable_state"] = json.loads((data / "state.json").read_text())["settings"]["onboardingComplete"]
    third = launch("third")
    checks["lock_released_for_next_launch"] = third.wait(timeout=15) == 0 and (data / "third.json").exists()
finally:
    for process in processes:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill(); process.wait()
    for log in logs:
        log.close()
result = {"passed": all(checks.values()), "checks": checks, "identity": identity["bundleIdentifier"], "logs": str(AUDIT)}
(AUDIT / "summary.json").write_text(json.dumps(result, indent=2))
print(json.dumps(result, indent=2))
raise SystemExit(0 if result["passed"] else 1)
