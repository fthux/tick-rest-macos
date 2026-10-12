#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
python3 scripts/check-localizations.py
developer_dir="$(xcode-select -p)"
if [ ! -d "$developer_dir/Platforms/MacOSX.platform/Developer/Library/Frameworks/XCTest.framework" ]; then
    if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks/XCTest.framework ]; then
        export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
        developer_dir="$DEVELOPER_DIR"
        printf 'Using Xcode for XCTest: %s\n' "$DEVELOPER_DIR"
    else
        printf 'Tests require full Xcode with XCTest. Set DEVELOPER_DIR to its Contents/Developer directory.\n' >&2
        exit 1
    fi
fi
test_frameworks="$developer_dir/Library/Developer/Frameworks"
if [ -d "$test_frameworks/Testing.framework" ]; then
    xcrun swift test --disable-sandbox -Xswiftc -F -Xswiftc "$test_frameworks" -Xlinker -rpath -Xlinker "$test_frameworks" -Xlinker -rpath -Xlinker "$developer_dir/Library/Developer/usr/lib" "$@"
else
    xcrun swift test --disable-sandbox "$@"
fi
