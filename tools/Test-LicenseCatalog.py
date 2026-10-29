"""Check About notice reachability, reader limits, provenance and source export coverage."""
import hashlib
import json
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[1]


def main():
    catalog = json.loads((ROOT / 'app/godot/i18n/licenses.json').read_text(encoding='utf-8'))
    import subprocess
    public_files = set(subprocess.check_output(['git', 'ls-files'], cwd=ROOT, text=True).splitlines())
    ids, assets = set(), set()
    for entry in catalog:
        assert entry['id'] not in ids, f'Duplicate license ID: {entry["id"]}'
        ids.add(entry['id'])
        assert entry['name'] and entry['license']
        assert entry['assets'] or entry['id'] in ('godot', 'godot-third-party')
        for asset in entry['assets']:
            path = PurePosixPath(asset)
            assert not path.is_absolute() and '..' not in path.parts and ':' not in asset and '\\' not in asset, asset
            source = ROOT / 'third_party' / asset
            data = source.read_bytes()
            assert 0 < len(data) <= 256 * 1024, f'Outside Android reader limit: {asset}'
            assert data.decode('utf-8').strip(), f'Empty notice: {asset}'
            public_asset = {'tiff/README.ijg': 'tiff/LIBJPEG-TURBO-IJG.txt'}.get(asset, asset)
            assert f'third_party/{public_asset}' in public_files, f'Missing from source export policy: {asset}'
            if public_asset != asset:
                assert source.read_text(encoding='utf-8') == (ROOT / 'third_party' / public_asset).read_text(encoding='utf-8'), 'Public notice alias must preserve the exact license text'
            assets.add(asset)
    provenance = json.loads((ROOT / 'third_party/player-licenses/additional-sources.json').read_text(encoding='utf-8'))
    for record in provenance['files']:
        asset = record['path']
        assert asset in assets, f'Archived notice has no About entry: {asset}'
        # Git may check text out as CRLF on Windows; provenance hashes describe
        # the normalized UTF-8/LF text, not the checkout's newline convention.
        text = (ROOT / 'third_party' / asset).read_text(encoding='utf-8')
        assert hashlib.sha256(text.encode('utf-8')).hexdigest() == record['sha256'], asset
    # These are production model bundles, not experimental/research downloads.
    for manifest, license_id in {
        'narration/model.json': 'moss-tts',
        'narration/clone_model.json': 'moss-tts',
        'narration/vad_model.json': 'silero-vad',
        'comic-ocr/model.json': 'comic-ocr',
        'moonshine/model.json': 'moonshine',
        'web-video/runtime.json': 'yt-dlp',
        'geckoview/runtime.json': 'geckoview',
    }.items():
        assert (ROOT / 'third_party' / manifest).is_file() and license_id in ids, manifest
    print(f'About catalog: {len(ids)} entries, {len(assets)} readable assets, {len(provenance["files"])} verified notice sources')


if __name__ == '__main__':
    main()
