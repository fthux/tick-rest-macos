#!/usr/bin/env python3
"""Check translation parity, placeholders, and literal UI keys without dependencies."""
import json
import re
from pathlib import Path

root = Path(__file__).resolve().parent.parent
resources = root / "Sources/TickRestCore/Resources"
def read(path):
    pairs = re.findall(r'("(?:[^"\\]|\\.)*")\s*=\s*("(?:[^"\\]|\\.)*")\s*;', path.read_text())
    result = {json.loads(key): json.loads(value) for key, value in pairs}
    assert len(result) == len(pairs), f"Duplicate keys: {path}"
    return result
base = read(resources / "zh-Hans.lproj/Localizable.strings")
for path in resources.glob("*.lproj/Localizable.strings"):
    translated = read(path)
    assert base.keys() == translated.keys(), f"Translation keys differ: {path}"
    for key in base:
        placeholders = lambda s: re.findall(r'%(?!%)(?:\d+\$)?[@dfsu]', s)
        assert sorted(placeholders(base[key])) == sorted(placeholders(translated[key])), f"Placeholder mismatch: {path}:{key}"
        assert base[key].count("{appName}") == translated[key].count("{appName}"), f"App name token mismatch: {path}:{key}"
for path in (root / "Sources").rglob("*.swift"):
    for key in re.findall(r'(?:L10n\.text|row|toggle|metric)\("([^"\\]+)"', path.read_text()):
        assert key in base, f"Missing UI key: {path}:{key}"
    assert not re.search(r'[\u4e00-\u9fff]', path.read_text()), f"User text embedded in Swift: {path}"
print(f"Localization check passed: {len(base)} keys, {len(list(resources.glob('*.lproj')))} locale(s).")
