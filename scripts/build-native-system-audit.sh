#!/bin/bash
# Build isolated .apps using the current production sources, without adding a
# test entry point to the shipping app or touching its real data/login item.
set -euo pipefail
cd "$(dirname "$0")/.."
audit_root="$PWD/.build/native-system-audit"
mkdir -p "$audit_root/package/Sources"
python3 - "$PWD" "$audit_root" <<'PY'
import json, shutil, sys
from pathlib import Path
project, audit = map(Path, sys.argv[1:])
for name in ('TickRestCore', 'TickRestApp'):
    target = audit/'package'/'Sources'/name
    shutil.copytree(project/'Sources'/name, target, dirs_exist_ok=True)
shutil.copy2(project/'scripts/native-system-audit.swift', audit/'package/Sources/TickRestApp/main.swift')
(audit/'package/Sources/TickRestApp/AppDelegate.swift').unlink()
(audit/'package/Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "TickRestSystemAudit", defaultLocalization: "en", platforms: [.macOS(.v13)],
    products: [.executable(name: "SystemAudit", targets: ["TickRestApp"])],
    targets: [.target(name: "TickRestCore", resources: [.process("Resources")]),
              .executableTarget(name: "TickRestApp", dependencies: ["TickRestCore"])], swiftLanguageModes: [.v5])
''')
# Capture exactly which production sources were used for this run.
import hashlib
sources = {str(p.relative_to(project)): hashlib.sha256(p.read_bytes()).hexdigest()
           for p in (project/'Sources').rglob('*') if p.is_file()}
(audit/'source-sha256.json').write_text(json.dumps(sources, indent=2))
PY
swift build --package-path "$audit_root/package" --disable-sandbox
audit_binary_dir="$(swift build --package-path "$audit_root/package" --show-bin-path)"
python3 - "$audit_root" "$audit_binary_dir" <<'PY'
import plistlib, shutil, sys
from pathlib import Path
audit, binary = map(Path, sys.argv[1:])
for choice in ('denied', 'allowed'):
    app = audit/f'Tick Rest Audit {choice}.app'
    (app/'Contents/MacOS').mkdir(parents=True, exist_ok=True)
    (app/'Contents/Resources').mkdir(parents=True, exist_ok=True)
    shutil.copy2(binary/'SystemAudit', app/'Contents/MacOS/SystemAudit')
    resources = binary/'TickRestSystemAudit_TickRestCore.bundle'
    shutil.copytree(resources, app/'Contents/Resources'/resources.name, dirs_exist_ok=True)
    info = dict(CFBundleIdentifier=f'app.restly.desktop.audit.{choice}',
        CFBundleName=f'Tick Rest Audit {choice}', CFBundleDisplayName=f'Tick Rest Audit {choice}',
        CFBundleExecutable='SystemAudit', CFBundlePackageType='APPL', CFBundleVersion='1',
        CFBundleShortVersionString='0.1', LSMinimumSystemVersion='13.0',
        AppResourceBundle=resources.stem, NSHighResolutionCapable=True)
    with (app/'Contents/Info.plist').open('wb') as f: plistlib.dump(info, f)
    (audit/choice).mkdir(exist_ok=True)
PY
for choice in denied allowed; do
    codesign --force --deep --sign - "$audit_root/Tick Rest Audit $choice.app"
    codesign --verify --deep --strict "$audit_root/Tick Rest Audit $choice.app"
done
printf 'Built isolated native test apps in %s\n' "$audit_root"
