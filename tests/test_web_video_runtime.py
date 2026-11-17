"""Offline compatibility checks against the exact extractor shipped in the APK."""
import ast
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = ROOT / 'build/web-video/yt-dlp.zip'
sys.path.insert(0, str(RUNTIME))


class RuntimeCompatibilityTest(unittest.TestCase):
    def test_pinned_archive_identity_and_android_python_syntax(self):
        pin = json.loads((ROOT / 'third_party/web-video/runtime.json').read_text())
        data = RUNTIME.read_bytes()
        self.assertEqual(pin['bytes'], len(data))
        self.assertEqual(pin['sha256'], hashlib.sha256(data).hexdigest())
        from yt_dlp import version
        self.assertEqual(pin['version'], version.__version__)
        self.assertEqual(pin['channel'], version.CHANNEL)
        self.assertEqual(pin['source_commit'], version.RELEASE_GIT_HEAD)
        with zipfile.ZipFile(RUNTIME) as archive:
            for name in archive.namelist():
                if name.endswith('.py'):
                    ast.parse(archive.read(name), filename=name, feature_version=(3, 12))

    def test_bundled_solver_matches_declared_notice(self):
        from yt_dlp_ejs import version
        from yt_dlp_ejs.yt import solver
        notice = (ROOT / 'third_party/web-video/RUNTIME-NOTICE.txt').read_text(encoding='utf-8')
        self.assertIn('yt-dlp-ejs ' + version + ' ', notice)
        self.assertTrue(solver.core())
        self.assertTrue(solver.lib())

    def test_production_entrypoint_keeps_output_and_cookie_boundary(self):
        from yt_dlp import YoutubeDL
        from yt_dlp.extractor.bilibili import BilibiliBaseIE
        from yt_dlp.globals import plugin_dirs
        spec = importlib.util.spec_from_file_location('runtime_runner', ROOT / 'android/player-plugin/src/main/assets/web-video/extract.py')
        runner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(runner)
        result = {'id': 'synthetic', 'title': 'Fixture', 'duration': 4,
                  'formats': [{'format_id': '18', 'url': 'https://cdn.example.test/video.mp4',
                               'ext': 'mp4', 'vcodec': 'avc1', 'acodec': 'mp4a', 'protocol': 'https',
                               'http_headers': {'Cookie': 'must-not-spread'}, 'cookies': 'private'}],
                  'requested_formats': [{'private': 'omit'}]}
        output = io.StringIO()
        payload = io.TextIOWrapper(io.BytesIO(b'[]'), encoding='utf-8')
        with patch.object(sys, 'argv', ['extract.py', str(RUNTIME), '', 'https://www.youtube.com/watch?v=aqz-KE-bpKQ']), \
                patch.object(sys, 'stdin', payload), patch.object(sys, 'stdout', output), \
                patch.object(sys, 'stderr', io.StringIO()), \
                patch.object(plugin_dirs, 'value', []), \
                patch.object(BilibiliBaseIE, 'extract_formats', BilibiliBaseIE.extract_formats), \
                patch.object(YoutubeDL, 'extract_info', return_value=result) as extract_info:
            runner.main()
        extract_info.assert_called_once_with('https://www.youtube.com/watch?v=aqz-KE-bpKQ', download=False)
        decoded = json.loads(output.getvalue())
        self.assertEqual('synthetic', decoded['id'])
        self.assertEqual(1, len(decoded['formats']))
        self.assertNotIn('Cookie', decoded['formats'][0]['http_headers'])
        self.assertNotIn('cookies', decoded['formats'][0])
        self.assertNotIn('requested_formats', decoded)


if __name__ == '__main__':
    unittest.main()
