"""Prepare the public image acceptance corpus without touching devices or application data."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import shutil
import time
import urllib.request
import urllib.parse

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--destination', type=Path, default=ROOT/'build/output/image-fixtures')
    args = parser.parse_args()
    manifest = json.loads((ROOT / 'tests/fixtures/image-formats/sources.json').read_text(encoding='utf-8-sig'))
    destination = args.destination.resolve()
    destination.mkdir(parents=True, exist_ok=True)

    def prepare(item):
        raw = 'provider_sha256' in item
        name = (item['make'] + '-' + item['model'] + '.' + item['format'].lower()) if raw else item['name']
        name = ''.join(c if c not in '<>:"/\\|?*' else '_' for c in name)
        group = 'RAW' if raw else ('Invalid' if item.get('inspection', {}).get('expected_invalid') else 'Unsupported' if item.get('expected_unsupported') else item['format'])
        target = destination / group / name
        target.parent.mkdir(parents=True, exist_ok=True)
        expected = item['provider_sha256'] if raw else item['sha256']
        def digest(path):
            with path.open('rb') as stream:
                return hashlib.file_digest(stream, 'sha256').hexdigest()
        if target.exists():
            if digest(target) != expected:
                raise RuntimeError(f'Existing fixture differs, preserved: {target}')
        else:
            partial = target.with_suffix(target.suffix + '.part')
            cached = ROOT / item.get('cache_path', '__missing__')
            if cached.is_file() and digest(cached) == expected:
                shutil.copyfile(cached, partial)
            else:
                url = urllib.parse.quote(item['url'], safe=':/?=&%')
                for attempt in range(3):
                    offset = partial.stat().st_size if partial.exists() else 0
                    headers = {'User-Agent': 'Thru3D-test-fixtures/1.0'}
                    if offset:
                        headers['Range'] = f'bytes={offset}-'
                    try:
                        request = urllib.request.Request(url, headers=headers)
                        with urllib.request.urlopen(request, timeout=120) as source:
                            append = offset > 0 and source.status == 206
                            with partial.open('ab' if append else 'wb') as output:
                                shutil.copyfileobj(source, output)
                        break
                    except (TimeoutError, OSError):
                        if attempt == 2:
                            raise
                        time.sleep(2)
            if digest(partial) != expected:
                raise RuntimeError(f'Fixture checksum mismatch: {partial}')
            partial.replace(target)
        return {'path': target.relative_to(destination).as_posix(), 'sha256': expected, 'bytes': target.stat().st_size,
                'source': item['url'], 'license': item.get('license', item.get('license_note'))}

    with ThreadPoolExecutor(max_workers=2) as pool:
        files = list(pool.map(prepare, manifest['downloaded_samples'] + manifest['raw_samples']))
    existing=destination/'SOURCES.json'
    if existing.exists():
        for item in json.loads(existing.read_text(encoding='utf-8')):
            if item.get('generator')=='tools/media/Generate-ImageFixtures.py':
                path=destination/item['path']
                if path.is_file() and hashlib.sha256(path.read_bytes()).hexdigest()==item['sha256']:
                    files.append(item)
    (destination / 'SOURCES.json').write_text(json.dumps(files, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    (destination / 'README.txt').write_text(
        'Thru3D image acceptance fixtures\n\nAVIF / APNG / GIF / WEBP: still and animation examples.\n'
        'RAW: real camera originals; preview and full RAW decode are separate checks.\n'
        'Invalid: intentionally malformed input, expected to fail safely.\n'
        'SOURCES.json records source URLs and verified SHA-256. Fixtures do not ship in the APK.\n', encoding='utf-8')
    guide=destination/'验收说明.md'
    if not guide.exists():
        shutil.copyfile(ROOT/'tests/fixtures/image-formats/ACCEPTANCE.zh-CN.md',guide)
    print(json.dumps({'destination': str(destination), 'files': len(files), 'bytes': sum(f['bytes'] for f in files)}))


if __name__ == '__main__':
    main()
