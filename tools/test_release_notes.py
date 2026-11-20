import copy
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

from check_release_notes import check


class ReleaseNotesChecks(unittest.TestCase):
    def setUp(self):
        output = Path(__file__).resolve().parents[1] / 'build/version-history'
        output.mkdir(parents=True, exist_ok=True)
        temp = tempfile.TemporaryDirectory(dir=output)
        self.addCleanup(temp.cleanup)
        self.snapshot = Path(temp.name) / 'release_notes.json'
        text = {'en': 'One', 'ja': '一', 'zh': '一', 'zh_Hant': '一'}
        self.current = {'version': '0.17.12', 'date': '2026-11-15', 'title': text,
                        'items': [{'id': 'first', 'text': text.copy()}]}
        self.future = dict(self.current, version='0.18.3')
        self.data = {'schema': 1, 'entries': [self.future, self.current]}
        self.write()

    def write(self):
        self.snapshot.write_text(json.dumps(self.data), encoding='utf-8')

    def test_exact_display_version_required_only_in_release(self):
        self.assertEqual(check(self.snapshot, '0.17.12'), 1)
        with self.assertRaisesRegex(ValueError, 'exact release notes'):
            check(self.snapshot, '0.17.12.1')
        self.assertEqual(check(self.snapshot, '0.17.12.1', debug=True), 1)

    def test_missing_current_translation_in_either_format(self):
        self.current['items'][0]['text'].pop('ja')
        self.write()
        with self.assertRaisesRegex(ValueError, 'ja notes'):
            check(self.snapshot, '0.17.12')
        self.assertEqual(check(self.snapshot, '0.17.12', debug=True), 1)
        self.current.pop('items')
        self.current['notes'] = {'en': ['One'], 'zh': ['一'], 'ja': ['一']}
        self.write()
        with self.assertRaisesRegex(ValueError, 'zh_Hant notes'):
            check(self.snapshot, '0.17.12')

    def test_packaged_history_matches_all_languages_at_the_installed_cap(self):
        archive = self.snapshot.with_suffix('.apk')
        def pack(rows):
            with zipfile.ZipFile(archive, 'w') as apk:
                apk.writestr('assets/data/release_notes.json', json.dumps({'schema': 1, 'entries': rows}))
        pack([self.current])
        self.assertEqual(check(self.snapshot, '0.17.12', archive=archive), 1)
        for invalid in [self.data['entries'], [], [copy.deepcopy(self.current)]]:
            if len(invalid) == 1:
                invalid[0]['items'][0]['text']['ja'] = '別'
            pack(invalid)
            with self.assertRaisesRegex(ValueError, 'differ'):
                check(self.snapshot, '0.17.12', archive=archive)


if __name__ == '__main__':
    unittest.main()
