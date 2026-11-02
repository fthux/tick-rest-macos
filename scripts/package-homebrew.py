#!/usr/bin/env python3
"""Package built apps as ZIP archives and generate a Homebrew cask with GitHub Release URLs."""

import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
from urllib.parse import urlparse


ROOT = Path(__file__).resolve().parents[1]
ARCHITECTURES = ("universal", "arm64", "x86_64")


def ruby_string(value):
    # JSON string syntax is also valid Ruby; escape Ruby interpolation as well.
    return json.dumps(value, ensure_ascii=False).replace("#{", r"\#{")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("variant", choices=("release", "dev"))
    parser.add_argument("--architectures", nargs="+", choices=ARCHITECTURES, default=ARCHITECTURES,
                        help="Architectures to package; defaults to all three")
    parser.add_argument("--base-url", help="GitHub Release download directory; defaults to the channel repository's v<version> tag")
    parser.add_argument("--output", type=Path,
                        help="Generated cask path; defaults to tickrest.rb or tickrest-dev.rb in the build directory")
    args = parser.parse_args()
    is_dev = args.variant == "dev"
    token = "tickrest-dev" if is_dev else "tickrest"
    other_token = "tickrest" if is_dev else "tickrest-dev"
    repository = "tick-rest-macos-dev" if is_dev else "tick-rest-macos"
    arch_variable = "HOMEBREW_TICKREST_DEV_ARCH" if is_dev else "HOMEBREW_TICKREST_ARCH"
    architectures = tuple(dict.fromkeys(args.architectures))
    default_architecture = "universal" if "universal" in architectures else architectures[0]
    template = plistlib.loads((ROOT / "packaging/Info.plist").read_bytes())
    version, build = (template[key] for key in ("CFBundleShortVersionString", "CFBundleVersion"))
    if not all(isinstance(value, str) and re.fullmatch(r"\d+(?:\.\d+)*", value) for value in (version, build)):
        parser.error("App version and build must contain only numbers and dots")
    dist = ROOT / "dist" / f"v{version}-{build}-{args.variant}"
    output = args.output or dist / f"{token}.rb"
    release_prefix = f"https://github.com/fthux/{repository}/releases/download/"
    base_url = (args.base_url or f"{release_prefix}v{version}").rstrip("/")
    parsed_url = urlparse(base_url)
    tag = base_url.removeprefix(release_prefix)
    if (not base_url.startswith(release_prefix) or not re.fullmatch(r"[A-Za-z0-9._-]+", tag)
            or parsed_url.query or parsed_url.fragment):
        parser.error(f"--base-url must be {release_prefix}<tag>")

    apps = {}
    identity = None
    for architecture in architectures:
        app = dist / f"Tick Rest-{architecture}.app"
        with (app / "Contents/Info.plist").open("rb") as source:
            info = plistlib.load(source)
        current_identity = tuple(info[key] for key in (
            "CFBundleShortVersionString", "CFBundleVersion", "LSMinimumSystemVersion",
        ))
        if current_identity[:2] != (version, build):
            parser.error(f"App version and build must match the build directory: {app}")
        if identity is None:
            identity = current_identity
        if identity != current_identity:
            parser.error("All apps must have matching versions, build numbers and minimum macOS versions")
        if (info.get("AppBuildArchitecture") != architecture
                or info.get("AppBuildConfiguration") != ("debug" if is_dev else "release")
                or info.get("AppDistributionChannel") != ("dev" if is_dev else "stable")
                or info.get("CFBundleIdentifier") != "app.tickrest.desktop"):
            parser.error(f"Unexpected app identity or build configuration: {app}")
        executable = app / "Contents/MacOS" / info["CFBundleExecutable"]
        actual = set(subprocess.check_output(["/usr/bin/lipo", "-archs", str(executable)], text=True).split())
        expected = {"arm64", "x86_64"} if architecture == "universal" else {architecture}
        if actual != expected:
            parser.error(f"Unexpected binary architectures in {app}: {actual}")
        subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
        apps[architecture] = app

    version, build, minimum_macos = identity
    macos_symbols = {"11": "big_sur", "12": "monterey", "13": "ventura",
                     "14": "sonoma", "15": "sequoia", "26": "tahoe"}
    minimum_macos_symbol = macos_symbols.get(minimum_macos.split(".")[0])
    if minimum_macos_symbol is None:
        parser.error(f"Add a Homebrew macOS symbol for {minimum_macos} before packaging")
    checksums = {}
    urls = {}
    for architecture, app in apps.items():
        filename = f"TickRest-{version}-{architecture}.zip"
        archive = dist / filename
        with tempfile.TemporaryDirectory(prefix=f"{token}-", dir=dist) as temporary:
            staged_archive = Path(temporary) / filename
            # Keep the archive's app name compatible with the Cask install path.
            staged_app = Path(temporary) / f"Tick Rest-{architecture}.app"
            shutil.copytree(app, staged_app, symlinks=True)
            subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(staged_app)], check=True)
            subprocess.run([
                "/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent",
                str(staged_app), str(staged_archive),
            ], check=True)
            checksums[architecture] = hashlib.sha256(staged_archive.read_bytes()).hexdigest()
            staged_archive.replace(archive)
        urls[architecture] = f"{base_url}/{filename}"
        print(f"{architecture}: {archive}\n  sha256 {checksums[architecture]}")

    variants = "\n".join(
        f'    {ruby_string(architecture)} => [{ruby_string(urls[architecture])}, '
        f'{ruby_string(checksums[architecture])}],'
        for architecture in architectures
    )
    source = '''# Generated by scripts/package-homebrew.py; upload these exact ZIPs to the GitHub Release.
# Select with __ARCH_VARIABLE__ (default: __DEFAULT_ARCHITECTURE__).
cask "__TOKEN__" do
  selected_arch = ENV.fetch("__ARCH_VARIABLE__", "__DEFAULT_ARCHITECTURE__")
  selected_arch = { "arm" => "arm64", "intel" => "x86_64" }.fetch(selected_arch, selected_arch)
  variants = {
__VARIANTS__
  }
  unless variants.key?(selected_arch)
    raise ArgumentError, "__ARCH_VARIABLE__ must select an available architecture: #{variants.keys.join(', ')} (aliases: arm, intel)"
  end
  download_url, checksum = variants.fetch(selected_arch)

  version __VERSION__
  sha256 checksum

  url download_url
  name "__DISPLAY_NAME__"
  desc "Yet another break time reminder app.Take regular breaks from your computer to rest your eyes, relax, and move around."
  homepage "https://github.com/fthux/__REPOSITORY__"

  livecheck do
    skip "Update the cask after publishing the release ZIPs"
  end

  conflicts_with cask: "__OTHER_TOKEN__"
  depends_on macos: :__MINIMUM_MACOS__
  depends_on arch: :arm64 if selected_arch == "arm64"
  depends_on arch: :x86_64 if selected_arch == "x86_64"

  app "Tick Rest-#{selected_arch}.app", target: "Tick Rest.app"

  postflight_steps do
    run "/usr/bin/xattr",
        args: ["-dr", "com.apple.quarantine", "{{appdir}}/Tick Rest.app"],
        writable_paths: ["Tick Rest.app"],
        writable_base: :appdir
  end

  uninstall quit: "app.tickrest.desktop"
end
'''
    source = source.replace("__VARIANTS__", variants)
    source = source.replace("__VERSION__", ruby_string(f"{version},{build}"))
    source = source.replace("__MINIMUM_MACOS__", minimum_macos_symbol)
    source = source.replace("__TOKEN__", token).replace("__OTHER_TOKEN__", other_token)
    source = source.replace("__ARCH_VARIABLE__", arch_variable).replace("__DEFAULT_ARCHITECTURE__", default_architecture)
    source = source.replace("__REPOSITORY__", repository).replace("__DISPLAY_NAME__", "Tick Rest Dev" if is_dev else "Tick Rest")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(source, encoding="utf-8")
    print(f"Generated: {output}")



if __name__ == "__main__":
    main()
