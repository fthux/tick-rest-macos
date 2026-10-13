"""Read-only integration checks for the actual .app produced by build-app.sh.

Run after building: python3 -m unittest discover -s Tests/PackagingTests -v
Defaults to all Release variants. TICKREST_BUILD_CONFIGURATION and
TICKREST_BUILD_ARCHITECTURE select the same options as build-app.sh.
No app is launched; the user's preferences and statistics are never modified.
"""
import json
import os
from pathlib import Path
import plistlib
import platform
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[2]
IDENTITY = json.loads((ROOT / "Sources/TickRestCore/Resources/AppIdentity.json").read_text())
CONFIGURATION = os.environ.get("TICKREST_BUILD_CONFIGURATION", "release")


class PackagingTests(unittest.TestCase):
    architecture = "universal"

    @classmethod
    def setUpClass(cls):
        cls.app = ROOT / "dist" / f"{IDENTITY['name']}-macOS-{cls.architecture}-{CONFIGURATION}.app"
        if not cls.app.is_dir():
            raise RuntimeError(f"Build the app first: bash scripts/build-app.sh {CONFIGURATION} {cls.architecture}")
        cls.info = plistlib.loads((cls.app / "Contents/Info.plist").read_bytes())
        cls.resources = cls.app / "Contents/Resources" / (cls.info["AppResourceBundle"] + ".bundle")
        if (cls.resources / "Contents/Resources").is_dir():
            cls.resources /= "Contents/Resources"

    def test_identity_matches_executable_and_bundle_id(self):
        for key in ("CFBundleName", "CFBundleDisplayName", "CFBundleExecutable"):
            self.assertEqual(self.info[key], IDENTITY["name"])
        self.assertEqual(self.info["CFBundleIdentifier"], IDENTITY["bundleIdentifier"])
        executable = self.app / "Contents/MacOS" / self.info["CFBundleExecutable"]
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
        self.assertNotIn("$(", (self.app / "Contents/Info.plist").read_text())

    def test_about_build_metadata_matches_packaged_variant(self):
        self.assertEqual(self.info["AppBuildArchitecture"], self.architecture)
        self.assertEqual(self.info["AppBuildConfiguration"], CONFIGURATION)
        template = plistlib.loads((ROOT / "packaging/Info.plist").read_bytes())
        for key in ("CFBundleShortVersionString", "CFBundleVersion"):
            self.assertEqual(self.info[key], template[key])

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
                self.assertGreaterEqual(len(values), 203)
                for plan in ("tickrest", "eye202020", "fiftyTen", "pomodoro", "custom"):
                    self.assertIn(f"plan.{plan}", values)
                    self.assertIn(f"plan.{plan}.description", values)
                for key in ("settings.overview", "overview.period", "overview.period.today", "overview.period.yesterday", "overview.period.last7", "overview.period.last30", "overview.period.custom", "overview.start_date", "overview.end_date", "overview.empty", "overview.retention", "overview.partial_day"):
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
        icon = self.app / "Contents/Resources" / (self.info["CFBundleIconFile"] + ".icns")
        data = icon.read_bytes()
        self.assertEqual(data[:4], b"icns")
        self.assertEqual(int.from_bytes(data[4:8], "big"), len(data))

    def test_development_signature_passes_strict_verification(self):
        result = subprocess.run(["codesign", "--verify", "--deep", "--strict", str(self.app)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_binary_architectures_match_artifact_name(self):
        executable = self.app / "Contents/MacOS" / self.info["CFBundleExecutable"]
        architectures = subprocess.check_output(["lipo", "-archs", str(executable)], text=True).split()
        expected = {"arm64", "x86_64"} if self.architecture == "universal" else {self.architecture}
        self.assertEqual(set(architectures), expected)

    def test_binary_deployment_target_matches_advertised_macos13(self):
        # Info.plist alone cannot guarantee that the compiled binary runs on macOS 13.
        executable = self.app / "Contents/MacOS" / self.info["CFBundleExecutable"]
        commands = subprocess.check_output(["otool", "-l", str(executable)], text=True)
        targets = [line.strip().split()[1] for line in commands.splitlines()
                   if line.strip().startswith("minos ")]
        self.assertTrue(targets, "No LC_BUILD_VERSION deployment target found")
        self.assertTrue(all(float(value.split(".")[0]) <= 13 for value in targets), targets)

    def test_runtime_dependencies_do_not_reference_build_directories(self):
        executable = self.app / "Contents/MacOS" / self.info["CFBundleExecutable"]
        output = subprocess.check_output(["otool", "-L", str(executable)], text=True)
        # Universal binaries have a separate, unindented heading per architecture.
        linked = [line for line in output.splitlines() if line.startswith(("\t", " "))]
        self.assertTrue(linked)
        for line in linked:
            dependency = line.strip().split(" (", 1)[0]
            with self.subTest(dependency=dependency):
                self.assertTrue(dependency.startswith(("/System/Library/", "/usr/lib/", "@rpath/")), dependency)


def load_tests(loader, tests, pattern):
    architecture = os.environ.get("TICKREST_BUILD_ARCHITECTURE", "all")
    if architecture == "native":
        architecture = platform.machine()
    if CONFIGURATION not in ("debug", "release") or architecture not in ("all", "arm64", "x86_64", "universal"):
        raise ValueError("Invalid build configuration or architecture")
    architectures = ("arm64", "x86_64", "universal") if architecture == "all" else (architecture,)
    suite = unittest.TestSuite()
    for target in architectures:
        case = type(f"PackagingTests_{target}", (PackagingTests,), {"architecture": target})
        suite.addTests(loader.loadTestsFromTestCase(case))
    return suite


if __name__ == "__main__":
    unittest.main()
