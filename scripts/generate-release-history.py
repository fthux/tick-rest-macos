#!/usr/bin/env python3
"""Generate the static release history and, explicitly, a Homebrew-ready feed."""
import argparse
import html
from html.parser import HTMLParser
import json
import os
from pathlib import Path
import plistlib
import re
import sys
import urllib.request

from markdown_it import MarkdownIt

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "fthux/tick-rest-macos"
HISTORY_URL = "https://fthux.github.io/tick-rest-macos/release-history.html"
VERSION = re.compile(r"(?:0|[1-9][0-9]*)(?:\.(?:0|[1-9][0-9]*)){0,2}\Z")
MARKDOWN = MarkdownIt("commonmark", {"html": False}).enable("table")


def version_key(value):
    if not isinstance(value, str) or not VERSION.fullmatch(value):
        raise ValueError(f"Not a stable numeric version: {value!r}")
    parts = [int(part) for part in value.split(".")]
    if any(part > 2**63 - 1 for part in parts):
        raise ValueError("Version components exceed the app's integer range")
    return tuple(parts + [0] * (3 - len(parts)))


def release_version(release):
    tag = release.get("tag_name", "")
    return tag[1:] if tag.startswith("v") else tag


def stable_releases(releases):
    result = []
    seen = set()
    for release in releases:
        if release.get("draft") or release.get("prerelease") or not release.get("published_at"):
            continue
        try:
            key = version_key(release_version(release))
        except ValueError:
            continue
        if key in seen:
            raise ValueError(f"Duplicate equivalent release version: {release_version(release)}")
        seen.add(key)
        result.append(release)
    return sorted(result, key=lambda item: version_key(release_version(item)), reverse=True)


def fetch_releases():
    releases = []
    for page in range(1, 1001):
        headers = {"Accept": "application/vnd.github+json", "User-Agent": "tick-rest-release-history"}
        if token := os.environ.get("GITHUB_TOKEN"):
            headers["Authorization"] = f"Bearer {token}"
        request = urllib.request.Request(
            f"https://api.github.com/repos/{REPOSITORY}/releases?per_page=100&page={page}", headers=headers)
        with urllib.request.urlopen(request, timeout=30) as response:
            batch = json.load(response)
        if not isinstance(batch, list):
            raise ValueError("GitHub did not return a release list")
        releases.extend(batch)
        if len(batch) < 100:
            return releases
    raise ValueError("Release list exceeds pagination limit")


class SummaryParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.parts = []

    def handle_starttag(self, tag, attrs):
        if tag == "li":
            self.parts.append("\n• ")
        elif tag in {"p", "h1", "h2", "h3", "h4", "h5", "h6", "pre", "br"}:
            self.parts.append("\n")

    def handle_endtag(self, tag):
        if tag in {"p", "li", "h1", "h2", "h3", "h4", "h5", "h6", "pre"}:
            self.parts.append("\n")

    def handle_data(self, data):
        self.parts.append(data)


def plain_summary(body):
    parser = SummaryParser()
    parser.feed(MARKDOWN.render(body or ""))
    text = "\n".join(line.rstrip() for line in "".join(parser.parts).splitlines()).strip()
    text = re.sub(r"\n{3,}", "\n\n", text)
    if len(text) > 4000:
        boundary = text.rfind("\n", 3000, 3999)
        text = text[:boundary if boundary > 0 else 3999].rstrip() + "…"
    return text


def make_manifest(releases, version, minimum_system):
    key = version_key(version.removeprefix("v"))
    version_key(minimum_system)
    release = next((item for item in releases if version_key(release_version(item)) == key), None)
    if release is None:
        raise ValueError(f"No published stable release for {version}")
    tag = release["tag_name"]
    return {
        "schemaVersion": 1,
        "version": release_version(release),
        "minimumSystemVersion": minimum_system,
        "releaseNotesURL": f"https://github.com/{REPOSITORY}/releases/tag/{tag}",
        "releaseHistoryURL": HISTORY_URL,
        "summary": plain_summary(release.get("body")),
    }


def render_history(releases, app_name):
    sections = []
    for release in releases:
        version = release_version(release)
        anchor = "v" + version.replace(".", "-")
        date = html.escape(release["published_at"][:10])
        body = MARKDOWN.render(release.get("body") or "")
        sections.append(f'<article id="{anchor}"><header><h2><a href="#{anchor}">'
                        f'{html.escape(app_name)} {version}</a></h2><time>{date}</time></header>'
                        f'<div class="notes">{body}</div></article>')
    if not sections:
        sections.append('<p class="empty">暂无正式版本记录。No stable releases yet.</p>')
    title = html.escape(app_name) + " · Release History"
    return f'''<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src https:; base-uri 'none'">
<title>{title}</title>
<style>
:root {{ color-scheme: light dark; --text: #252525; --muted: #737373; --line: #e5e5e5; --background: #fff; --link: #1761bd; }}
@media(prefers-color-scheme:dark) {{ :root {{ --text:#e8e8e8; --muted:#aaa; --line:#383838; --background:#1e1e1e; --link:#81b5ff; }} }}
* {{ box-sizing:border-box; }}
body {{ margin:0; background:var(--background); color:var(--text); font:16px/1.75 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; }}
main {{ max-width:800px; margin:auto; padding:48px 28px 80px; }}
.page-header {{ margin-bottom:44px; }}
h1 {{ font-size:30px; line-height:1.3; margin:0 0 8px; }}
.subtitle,time {{ color:var(--muted); font-size:14px; }}
article {{ border-top:1px solid var(--line); padding:32px 0; scroll-margin-top:24px; }}
article h2 {{ font-size:24px; line-height:1.4; margin:0 0 4px; }}
article h2 a {{ color:inherit; text-decoration:none; }}
.notes h1,.notes h2,.notes h3,.notes h4 {{ font-size:17px; margin:24px 0 8px; }}
p,ul,ol {{ margin:8px 0 16px; }} ul,ol {{ padding-left:24px; }} li {{ margin:4px 0; }}
a {{ color:var(--link); text-underline-offset:3px; }} a:hover {{ text-decoration:underline; }}
pre {{ overflow:auto; padding:16px; background:var(--line); border-radius:8px; }}
code {{ font-size:.9em; }} img {{ max-width:100%; }} table {{ display:block; overflow:auto; border-collapse:collapse; }}
th,td {{ border:1px solid var(--line); padding:6px 12px; }}
@media(max-width:480px) {{ main {{ padding:28px 20px 48px; }} h1 {{ font-size:26px; }} }}
</style></head><body><main><header class="page-header"><h1>{html.escape(app_name)}</h1>
<div class="subtitle">版本历史 / Release History</div></header>
{''.join(sections)}
</main></body></html>
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--releases", type=Path, help="Offline GitHub Releases API JSON fixture")
    parser.add_argument("--site-output", type=Path, required=True)
    parser.add_argument("--manifest-output", type=Path)
    parser.add_argument("--version", help="Homebrew-ready version/tag; never inferred from newest Release")
    parser.add_argument("--minimum-system", help="Minimum macOS for the selected release; defaults to packaging/Info.plist")
    parser.add_argument("--homebrew-ready", action="store_true", help="Confirm the selected version is installable from Homebrew")
    args = parser.parse_args()
    if args.manifest_output and not (args.version and args.homebrew_ready):
        parser.error("Generating a feed requires --version and --homebrew-ready")
    releases = stable_releases(json.loads(args.releases.read_text()) if args.releases else fetch_releases())
    name = json.loads((ROOT / "Sources/TickRestCore/Resources/AppIdentity.json").read_text())["name"]
    manifest = None
    if args.manifest_output:
        with (ROOT / "packaging/Info.plist").open("rb") as source:
            minimum = args.minimum_system or plistlib.load(source)["LSMinimumSystemVersion"]
        manifest = make_manifest(releases, args.version, minimum)
        if args.manifest_output.exists():
            previous = json.loads(args.manifest_output.read_text())
            if version_key(manifest["version"]) < version_key(previous["version"]):
                raise ValueError("Refusing to downgrade the published update feed")
    args.site_output.mkdir(parents=True, exist_ok=True)
    (args.site_output / "release-history.html").write_text(render_history(releases, name), encoding="utf-8")
    (args.site_output / "index.html").write_text(
        '<!doctype html><meta charset="utf-8"><meta http-equiv="refresh" content="0;url=release-history.html">'
        '<a href="release-history.html">Release History</a>', encoding="utf-8")
    if manifest:
        args.manifest_output.parent.mkdir(parents=True, exist_ok=True)
        args.manifest_output.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Generated history for {len(releases)} stable releases in {args.site_output}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError) as error:
        sys.exit(f"Release generation failed: {error}")
