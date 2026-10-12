#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
configuration="${1:-release}"
architecture="${2:-all}"
if [ "$#" -gt 2 ] || [[ "$configuration" != "debug" && "$configuration" != "release" ]] || [[ "$architecture" != "all" && "$architecture" != "native" && "$architecture" != "arm64" && "$architecture" != "x86_64" && "$architecture" != "universal" ]]; then
    printf 'Usage: %s [debug|release] [all|native|arm64|x86_64|universal]\n' "$0" >&2
    exit 1
fi
if [ "$architecture" = "native" ]; then architecture="$(uname -m)"; fi
if [[ "$architecture" = "all" || "$architecture" = "universal" ]]; then
    # SwiftPM's multi-architecture backend requires full Xcode, not Command Line Tools.
    if ! xcrun --find xcodebuild >/dev/null 2>&1; then
        if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
            export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
            printf 'Using Xcode for multi-architecture build: %s\n' "$DEVELOPER_DIR"
        fi
        if ! xcrun --find xcodebuild >/dev/null 2>&1; then
            printf 'Multi-architecture builds require full Xcode. Set DEVELOPER_DIR to its Contents/Developer directory, or build with: bash scripts/build-app.sh %s native\n' "$configuration" >&2
            exit 1
        fi
    fi
fi
# Resolve Swift from the selected developer directory, including the fallback above.
swift_command=(xcrun swift)
build_args=(-c "$configuration" --disable-sandbox)
if [[ "$architecture" = "all" || "$architecture" = "universal" ]]; then
    build_args+=(--arch arm64 --arch x86_64)
else
    build_args+=(--arch "$architecture")
fi
identity_file="Sources/TickRestCore/Resources/AppIdentity.json"
app_name="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["name"])' "$identity_file")"
resource_bundle="${app_name}_TickRestCore"
"${swift_command[@]}" build "${build_args[@]}"
binary_dir="$("${swift_command[@]}" build "${build_args[@]}" --show-bin-path)"
if [[ "$architecture" = "all" || "$architecture" = "universal" ]]; then
    lipo "$binary_dir/$app_name" -verify_arch arm64 x86_64
fi

package_app() {
    local output_architecture="$1"
    local configuration_suffix=""
    if [ "$configuration" = "debug" ]; then configuration_suffix="-debug"; fi
    local app_dir="$PWD/dist/$app_name-$output_architecture$configuration_suffix.app"
    # Recreate only this variant so rebuilds cannot retain stale resources/signatures.
    rm -rf "$app_dir"
    mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
    if [[ "$architecture" = "all" && "$output_architecture" != "universal" ]]; then
        # Compile both architectures once; reuse their slices for standalone apps.
        lipo "$binary_dir/$app_name" -thin "$output_architecture" -output "$app_dir/Contents/MacOS/$app_name"
        chmod +x "$app_dir/Contents/MacOS/$app_name"
    else
        cp "$binary_dir/$app_name" "$app_dir/Contents/MacOS/$app_name"
    fi
    # Native and Xcode builds use different resource bundle layouts.
    cp -R "$binary_dir/$resource_bundle.bundle" "$app_dir/Contents/Resources/"
    python3 - "$identity_file" "$resource_bundle" "$app_dir/Contents/Info.plist" "$output_architecture" "$configuration" <<'PY'
import json
import plistlib
import sys
from pathlib import Path

identity = json.loads(Path(sys.argv[1]).read_text())
with open("packaging/Info.plist", "rb") as source:
    info = plistlib.load(source)
values = {
    "$(APP_NAME)": identity["name"],
    "$(APP_BUNDLE_IDENTIFIER)": identity["bundleIdentifier"],
    "$(APP_RESOURCE_BUNDLE)": sys.argv[2],
    "$(APP_BUILD_ARCHITECTURE)": sys.argv[4],
    "$(APP_BUILD_CONFIGURATION)": sys.argv[5],
}
info = {key: values.get(value, value) if isinstance(value, str) else value for key, value in info.items()}
with open(sys.argv[3], "wb") as destination:
    plistlib.dump(info, destination)
PY
    if [ -f packaging/AppIcon.icns ]; then cp packaging/AppIcon.icns "$app_dir/Contents/Resources/AppIcon.icns"; fi
    codesign --force --deep --sign - "$app_dir"
    codesign --verify --deep --strict "$app_dir"
    printf 'Built: %s\n' "$app_dir"
}

if [ "$architecture" = "all" ]; then
    output_architectures=(arm64 x86_64 universal)
else
    output_architectures=("$architecture")
fi
for output_architecture in "${output_architectures[@]}"; do
    package_app "$output_architecture"
done
