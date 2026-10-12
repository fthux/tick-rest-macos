#!/bin/bash
# Run only headless tests. Never launch Tick Rest or native UI audit fixtures.
# Includes audit regressions and excludes all native window fixtures.
set -uo pipefail
cd "$(dirname "$0")/.."
audit_dir="$PWD/.build/project-audit/$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$audit_dir"
export PYTHONDONTWRITEBYTECODE=1
export LLVM_PROFILE_FILE="$audit_dir/process-%p.profraw"
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
results=()
failures=0
run_check() {
    local name="$1"; shift
    "$@" > "$audit_dir/$name.log" 2>&1
    local result=$?
    results+=("$name:$result")
    printf '%s: exit %s (%s)\n' "$name" "$result" "$audit_dir/$name.log"
    if [ "$result" -ne 0 ]; then failures=$((failures + 1)); fi
    return "$result"
}
run_check localization python3 scripts/check-localizations.py
# Explicit allow-list excludes AppIntegrationTests and ExtendedAppAuditTests,
# whose fixtures call NSApplication.finishLaunching and order windows front.
run_check tests bash scripts/test.sh --no-parallel --enable-code-coverage --filter \
    'TickRestCoreTests|AppBuildInfoTests|AboutCountryTests|ReminderAppearanceTests|GentleReminderPresentationTests|ProjectHeadlessAuditTests|NotificationObservationsTests'
binary_dir="$(xcrun swift build --show-bin-path)"
app_name="$(python3 -c 'import json; print(json.load(open("Sources/TickRestCore/Resources/AppIdentity.json"))["name"])')"
test_binary="$binary_dir/${app_name}PackageTests.xctest/Contents/MacOS/${app_name}PackageTests"
shopt -s nullglob
profiles=("$binary_dir"/codecov/*.profraw)
shopt -u nullglob
if [ "${#profiles[@]}" -gt 0 ] && [ -f "$test_binary" ]; then
    if run_check coverage-merge xcrun llvm-profdata merge -sparse "${profiles[@]}" -o "$audit_dir/coverage.profdata"; then
        run_check coverage-core xcrun llvm-cov report "$test_binary" "-instr-profile=$audit_dir/coverage.profdata" Sources/TickRestCore/*.swift
        run_check coverage-app xcrun llvm-cov report "$test_binary" "-instr-profile=$audit_dir/coverage.profdata" Sources/TickRestApp/*.swift
    fi
else
    results+=("coverage:skipped"); failures=$((failures + 1))
fi
run_check build bash scripts/build-app.sh release
if [ "${results[${#results[@]}-1]}" = "build:0" ]; then
    run_check packaging python3 -m unittest discover -s Tests/PackagingTests -v
else
    results+=("packaging:skipped"); failures=$((failures + 1))
fi
check_shell_syntax() {
    local script
    for script in scripts/*.sh; do
        bash -n "$script" || return "$?"
        printf 'Syntax OK: %s\n' "$script"
    done
}
run_check shell-syntax check_shell_syntax
python3 - "$audit_dir" "${results[@]}" <<'PY'
import json
import sys
from pathlib import Path
directory = Path(sys.argv[1])
checks = dict(item.split(":", 1) for item in sys.argv[2:])
summary = {"passed": all(value == "0" for value in checks.values()),
           "checks": {key: int(value) if value != "skipped" else value for key, value in checks.items()},
           "logs": str(directory), "ui_launched": False}
(directory / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
print(json.dumps(summary, ensure_ascii=False, indent=2))
PY
if [ "$failures" -gt 0 ]; then exit 1; fi
