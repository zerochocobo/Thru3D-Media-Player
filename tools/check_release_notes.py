"""Check the Player's committed release notes and the actual Android export."""
import argparse
from datetime import date
import json
from pathlib import Path
import re
import sys
import zipfile


def version_key(version):
    if not re.fullmatch(r'[0-9]+(?:\.[0-9]+)+', version):
        raise ValueError(f'Invalid version {version!r}')
    parts = list(map(int, version.split('.')))
    while len(parts) > 1 and not parts[-1]:
        parts.pop()
    return tuple(parts)


def has_text(value):
    return isinstance(value, str) and bool(value.strip())


def check_copy(row, language):
    if not has_text(row['title'].get(language)):
        raise ValueError(f'{row["version"]} missing {language} title')
    if 'items' in row:
        if not isinstance(row['items'], list):
            raise ValueError(f'{row["version"]} invalid items')
        notes = [item['text'].get(language) for item in row['items']]
    else:
        if not isinstance(row['notes'].get(language), list):
            raise ValueError(f'{row["version"]} missing {language} notes')
        notes = [item.get('text') if isinstance(item, dict) else item
                 for item in row['notes'].get(language, [])]
    if not notes or not all(map(has_text, notes)):
        raise ValueError(f'{row["version"]} missing {language} notes')


def check(snapshot, version, debug=False, archive=None):
    data = json.loads(snapshot.read_text(encoding='utf-8'))
    if data['schema'] != 1 or not isinstance(data['entries'], list):
        raise ValueError('Invalid release notes catalog')
    cap = version_key(version)
    entries = data['entries']
    keys = [version_key(row['version']) for row in entries]
    if keys != sorted(set(keys), reverse=True):
        raise ValueError('Release notes must contain unique versions in descending order')
    included = [row for row in entries if version_key(row['version']) <= cap]
    if archive:
        with zipfile.ZipFile(archive) as apk:
            packed = json.loads(apk.read('assets/data/release_notes.json'))
        if packed != {'schema': 1, 'entries': included}:
            raise ValueError(f'Packaged release notes differ from source capped at {version}')
    for row in included:
        date.fromisoformat(row['date'])
        for lang in ('en', 'zh', 'zh_Hant', 'ja'):
            try:
                check_copy(row, lang)
            except ValueError as error:
                if not debug or row['version'] != version:
                    raise
                print(f'WARNING: {error}', file=sys.stderr)
    if not any(row['version'] == version for row in included):
        if not debug:
            raise ValueError(f'Missing exact release notes for {version}')
        print(f'WARNING: no release notes for Debug {version}', file=sys.stderr)
    return len(included)


def main():
    args = argparse.ArgumentParser()
    args.add_argument('snapshot', type=Path)
    args.add_argument('version')
    args.add_argument('--build-type', choices=['Debug', 'Release'], required=True)
    args.add_argument('--apk', type=Path)
    ns = args.parse_args()
    try:
        count = check(ns.snapshot, ns.version, ns.build_type == 'Debug', ns.apk)
    except (OSError, ValueError, TypeError, KeyError, zipfile.BadZipFile) as error:
        args.exit(1, f'Release notes check failed: {error}\n')
    print(f'Release notes checked for {ns.version}: {count} versions')


if __name__ == '__main__':
    main()
