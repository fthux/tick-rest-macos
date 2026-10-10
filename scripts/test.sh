#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
python3 scripts/check-localizations.py
developer_dir="$(xcode-select -p)"
test_frameworks="$developer_dir/Library/Developer/Frameworks"
if [ -d "$test_frameworks/Testing.framework" ]; then
    swift test --disable-sandbox -Xswiftc -F -Xswiftc "$test_frameworks" -Xlinker -rpath -Xlinker "$test_frameworks" -Xlinker -rpath -Xlinker "$developer_dir/Library/Developer/usr/lib" "$@"
else
    swift test --disable-sandbox "$@"
fi
