#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
configuration="${1:-release}"
architecture="${2:-native}"
if [ "$#" -gt 2 ] || [[ "$configuration" != "debug" && "$configuration" != "release" ]] || [[ "$architecture" != "native" && "$architecture" != "universal" ]]; then
    printf 'Usage: %s [debug|release] [native|universal]\n' "$0" >&2
    exit 1
fi
build_args=(-c "$configuration" --disable-sandbox)
if [ "$architecture" = "universal" ]; then
    build_args+=(--arch arm64 --arch x86_64)
fi
identity_file="Sources/TickRestCore/Resources/AppIdentity.json"
app_name="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["name"])' "$identity_file")"
resource_bundle="${app_name}_TickRestCore"
swift build "${build_args[@]}"
binary_dir="$(swift build "${build_args[@]}" --show-bin-path)"
if [ "$architecture" = "universal" ]; then
    lipo "$binary_dir/$app_name" -verify_arch arm64 x86_64
fi
app_dir="$PWD/dist/$app_name.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/$app_name" "$app_dir/Contents/MacOS/$app_name"
# Native and Xcode builds use different resource bundle layouts.
rm -rf "$app_dir/Contents/Resources/$resource_bundle.bundle"
cp -R "$binary_dir/$resource_bundle.bundle" "$app_dir/Contents/Resources/"
python3 - "$identity_file" "$resource_bundle" "$app_dir/Contents/Info.plist" <<'PY'
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
}
info = {key: values.get(value, value) if isinstance(value, str) else value for key, value in info.items()}
with open(sys.argv[3], "wb") as destination:
    plistlib.dump(info, destination)
PY
if [ -f packaging/AppIcon.icns ]; then cp packaging/AppIcon.icns "$app_dir/Contents/Resources/AppIcon.icns"; fi
codesign --force --deep --sign - "$app_dir"
codesign --verify --deep --strict "$app_dir"
printf 'Built: %s\n' "$app_dir"
