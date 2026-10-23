"""Import separately supplied MIT controller meshes only after all pinned hashes match."""
import argparse
import hashlib
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True,
                        help='Folder with six pinned GLBs, or the pinned webxr-input-profiles checkout')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    destination = root / 'app/godot/models/controllers/pico'
    manifest = json.loads((destination / 'manifest.json').read_text('utf-8'))
    pending = []
    for item in manifest['files']:
        name = item['file']
        if Path(name).name != name or not name.endswith('.glb'):
            raise ValueError('Invalid controller manifest path')
        profile, hand = Path(name).stem.rsplit('-', 1)
        source = args.source / name
        if not source.is_file():
            source = args.source / 'packages/assets/profiles' / profile / (hand + '.glb')
        data = source.read_bytes()
        if len(data) != item['bytes'] or hashlib.sha256(data).hexdigest() != item['sha256']:
            raise ValueError('Controller source differs from pinned bytes: ' + name)
        target = destination / name
        if target.is_symlink():
            raise ValueError('Controller destination must not be redirected')
        pending.append((target, data))
    for target, data in pending:
        target.write_bytes(data)
    print(f'Prepared {len(pending)} pinned controller meshes; import the Godot project next.')


if __name__ == '__main__':
    main()
