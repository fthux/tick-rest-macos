"""Read-only integration checks for the actual .app produced by build-app.sh.

Run after building: python3 -m unittest discover -s Tests/PackagingTests -v
No app is launched; the user's preferences and statistics are never modified.
"""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[2]
IDENTITY = json.loads((ROOT / "Sources/TickRestCore/Resources/AppIdentity.json").read_text())
APP = ROOT / "dist" / (IDENTITY["name"] + ".app")


class PackagingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not APP.is_dir():
            raise RuntimeError("Build the app first: ./scripts/build-app.sh")
        cls.info = plistlib.loads((APP / "Contents/Info.plist").read_bytes())
        cls.resources = APP / "Contents/Resources" / (cls.info["AppResourceBundle"] + ".bundle")

    def test_identity_matches_executable_and_compatible_bundle_id(self):
        for key in ("CFBundleName", "CFBundleDisplayName", "CFBundleExecutable"):
            self.assertEqual(self.info[key], IDENTITY["name"])
        self.assertEqual(self.info["CFBundleIdentifier"], IDENTITY["bundleIdentifier"])
        executable = APP / "Contents/MacOS" / self.info["CFBundleExecutable"]
        self.assertTrue(os.access(executable, os.X_OK))
        self.assertIn("Mach-O", subprocess.check_output(["file", str(executable)], text=True))

    def test_menu_bar_application_and_macos13_deployment_metadata(self):
        self.assertIs(self.info["LSUIElement"], True)
        self.assertIs(self.info["NSHighResolutionCapable"], True)
        self.assertEqual(self.info["LSMinimumSystemVersion"], "13.0")
        self.assertEqual(self.info["CFBundlePackageType"], "APPL")
        self.assertTrue(self.info["CFBundleShortVersionString"])
        self.assertTrue(self.info["CFBundleVersion"])

    def test_no_unexpanded_build_placeholders(self):
        self.assertNotIn("$(", (APP / "Contents/Info.plist").read_text())

    def test_embedded_identity_matches_source(self):
        self.assertEqual(json.loads((self.resources / "AppIdentity.json").read_text()), IDENTITY)

    def test_every_advertised_language_has_a_packaged_translation(self):
        actual = {p.name[:-6].lower(): p for p in self.resources.glob("*.lproj")}
        declared = {value.lower() for value in self.info["CFBundleLocalizations"]}
        self.assertEqual(set(actual), declared)
        self.assertIn(self.info["CFBundleDevelopmentRegion"].lower(), actual)
        for language in sorted(declared):
            with self.subTest(language=language):
                translation = actual[language] / "Localizable.strings"
                self.assertTrue(translation.is_file())
                output = subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(translation)])
                values = json.loads(output)
                self.assertEqual(len(values), 206)
                for key in ("settings.overview", "menu.overview", "overview.period", "overview.period.today", "overview.period.yesterday", "overview.period.last7", "overview.period.last30", "overview.period.custom", "overview.start_date", "overview.end_date", "overview.empty", "overview.retention", "overview.partial_day"):
                    self.assertIn(key, values)
                for key in ("reminder.start_mode", "reminder.start_mode_help", "start_mode.automatic", "start_mode.manual"):
                    self.assertIn(key, values)
                for key in ("reminder.size", "reminder.size_help", "reminder.size.normal", "reminder.size.small", "reminder.size.mini", "rest.idea"):
                    self.assertIn(key, values)
                self.assertTrue(all(values.values()))
                self.assertIn("{appName}", values["welcome.title"])

    def test_packaged_translations_equal_current_sources(self):
        source = ROOT / "Sources/TickRestCore/Resources"
        actual = {p.name.lower(): p for p in self.resources.glob("*.lproj")}
        for original in source.glob("*.lproj/Localizable.strings"):
            with self.subTest(language=original.parent.name):
                bundled = actual[original.parent.name.lower()] / original.name
                def read_strings(path):
                    return json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(path)]))
                self.assertEqual(read_strings(original), read_strings(bundled))

    def test_application_icon_has_valid_icns_header(self):
        icon = APP / "Contents/Resources" / (self.info["CFBundleIconFile"] + ".icns")
        data = icon.read_bytes()
        self.assertEqual(data[:4], b"icns")
        self.assertEqual(int.from_bytes(data[4:8], "big"), len(data))

    def test_development_signature_passes_strict_verification(self):
        result = subprocess.run(["codesign", "--verify", "--deep", "--strict", str(APP)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
