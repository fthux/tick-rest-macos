#!/bin/bash
# Run every automated functional layer, retaining failures for the audit report.
# Additional arguments are forwarded to swift test, e.g. --filter FunctionalAuditTests.
set -uo pipefail
cd "$(dirname "$0")/.."
log_dir="$PWD/.build/functional-audit/$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$log_dir"
results=()
failures=0

run_check() {
    local name="$1"
    shift
    "$@" 2>&1 | tee "$log_dir/$name.log"
    local result=${PIPESTATUS[0]}
    results+=("$name:$result")
    if [ "$result" -ne 0 ]; then failures=$((failures + 1)); fi
    return "$result"
}

run_check localization python3 scripts/check-localizations.py
run_check swift bash scripts/test.sh --enable-code-coverage "$@"
# SwiftPM skips merging coverage after a failing test run. Keep coverage useful
# for defect audits too, without converting failures into successes.
binary_dir="$(swift build --show-bin-path)"
app_name="$(python3 -c 'import json; print(json.load(open("Sources/TickRestCore/Resources/AppIdentity.json"))["name"])')"
test_binary="$binary_dir/${app_name}PackageTests.xctest/Contents/MacOS/${app_name}PackageTests"
shopt -s nullglob
raw_profiles=("$binary_dir"/codecov/*.profraw)
shopt -u nullglob
if [ "${#raw_profiles[@]}" -gt 0 ] && [ -f "$test_binary" ]; then
    if run_check coverage-merge xcrun llvm-profdata merge -sparse "${raw_profiles[@]}" -o "$log_dir/coverage.profdata"; then
        run_check coverage xcrun llvm-cov report "$test_binary" "-instr-profile=$log_dir/coverage.profdata" Sources/TickRestCore/*.swift
    fi
else
    results+=("coverage:skipped")
    failures=$((failures + 1))
    printf 'Coverage unavailable: no instrumented test binary or raw profiles found.\n'
fi
if run_check build bash scripts/build-app.sh debug; then
    run_check packaging env PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/PackagingTests -v
else
    results+=("packaging:skipped")
    printf 'Packaging checks skipped because the current source did not build.\n'
fi

python3 - "$log_dir" "${results[@]}" <<'PY'
import json
import sys
from pathlib import Path

directory = Path(sys.argv[1])
results = dict(entry.split(":", 1) for entry in sys.argv[2:])
summary = {
    "passed": all(value == "0" for value in results.values()),
    "checks": {key: int(value) if value != "skipped" else value for key, value in results.items()},
    "logs": str(directory),
}
(directory / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
print(json.dumps(summary, ensure_ascii=False, indent=2))
PY

if [ "$failures" -gt 0 ]; then exit 1; fi
