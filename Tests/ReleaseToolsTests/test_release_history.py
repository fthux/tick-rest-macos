import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('release_history', ROOT / 'scripts/generate-release-history.py')
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def release(version, body='## 新增功能\n\n- 支持检查更新\n\n## 问题修复\n\n- 修复布局', **extra):
    return dict(tag_name=f'v{version}', published_at='2026-10-22T00:00:00Z',
                body=body, draft=False, prerelease=False, **extra)


class ReleaseHistoryTests(unittest.TestCase):
    def test_only_published_stable_versions_sorted_numerically(self):
        beta = release('2.0.0-beta'); beta['prerelease'] = True
        draft = release('4.0.0'); draft['draft'] = True
        unpublished = release('5.0.0'); unpublished['published_at'] = None
        result = MODULE.stable_releases([release('1.9.0'), beta, draft, unpublished, release('1.10.0')])
        self.assertEqual([item['tag_name'] for item in result], ['v1.10.0', 'v1.9.0'])
        with self.assertRaises(ValueError):
            MODULE.stable_releases([release('1.0'), release('1.0.0')])

    def test_markdown_history_is_safe_and_has_version_anchors(self):
        body = '## Fixes\n\n- **Layout** and [details](https://example.com)\n\n<script>alert(1)</script>\n\n[bad](javascript:alert(1))'
        page = MODULE.render_history([release('1.2.0', body)], 'Tick Rest')
        self.assertIn('id="v1-2-0"', page)
        self.assertIn('<strong>Layout</strong>', page)
        self.assertIn('<h2>Fixes</h2>', page)
        self.assertIn('2026-10-22', page)
        self.assertNotIn('<script>', page)
        self.assertNotIn('href="javascript:', page)
        self.assertIn('prefers-color-scheme:dark', page)

    def test_feed_uses_selected_homebrew_ready_release_not_newest(self):
        releases = MODULE.stable_releases([release('1.1.0'), release('1.2.0')])
        manifest = MODULE.make_manifest(releases, 'v1.1.0', '13.0')
        self.assertEqual(manifest['version'], '1.1.0')
        self.assertEqual(manifest['releaseHistoryURL'], MODULE.HISTORY_URL)
        self.assertEqual(manifest['releaseNotesURL'], 'https://github.com/fthux/tick-rest-macos/releases/tag/v1.1.0')
        self.assertIn('新增功能', manifest['summary'])
        self.assertIn('• 支持检查更新', manifest['summary'])
        with self.assertRaises(ValueError):
            MODULE.make_manifest(releases, '2.0.0', '13.0')

    def test_summary_is_plain_text_with_paragraphs_and_bounded_length(self):
        self.assertEqual(MODULE.plain_summary('**Hello** [world](https://example.com)\n\nNext paragraph'),
                         'Hello world\n\nNext paragraph')
        self.assertEqual(MODULE.plain_summary(None), '')
        self.assertLessEqual(len(MODULE.plain_summary('Long paragraph ' * 1000)), 4000)

    def test_api_paginates_past_one_hundred_releases(self):
        class Response:
            def __init__(self, data): self.data = data
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def read(self): return json.dumps(self.data).encode()
        with patch.object(MODULE.urllib.request, 'urlopen', side_effect=[Response([release('1.0.0')] * 100), Response([release('1.1.0')])]) as get:
            self.assertEqual(len(MODULE.fetch_releases()), 101)
            self.assertIn('page=2', get.call_args.args[0].full_url)

    def test_cli_requires_homebrew_confirmation_and_refuses_feed_downgrades(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            fixture = root / 'releases.json'
            fixture.write_text(json.dumps([release('1.0.0'), release('1.2.0')]))
            feed = root / 'homebrew-update.json'
            command = [sys.executable, str(ROOT / 'scripts/generate-release-history.py'),
                       '--releases', str(fixture), '--site-output', str(root / 'site'), '--manifest-output', str(feed)]
            self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)
            subprocess.run(command + ['--version', '1.2.0', '--homebrew-ready'], check=True, capture_output=True)
            previous = feed.read_bytes()
            refused = subprocess.run(command + ['--version', '1.0.0', '--homebrew-ready'], capture_output=True)
            self.assertNotEqual(refused.returncode, 0)
            self.assertEqual(feed.read_bytes(), previous)
            self.assertTrue((root / 'site/release-history.html').exists())
            self.assertTrue((root / 'site/index.html').exists())


if __name__ == '__main__':
    unittest.main()
