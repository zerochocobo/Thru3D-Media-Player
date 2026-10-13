"""Fetch and verify the pinned MVC research decoder; does not alter player libs."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[2]


def main():
    manifest = json.loads((ROOT / 'third_party/edge264-mvc/manifest.json').read_text(encoding='utf-8'))
    cache = ROOT / 'tmp/mvc-research'
    cache.mkdir(parents=True, exist_ok=True)
    archive_path = cache / ('edge264-mvc-' + manifest['revision'] + '.tar.gz')
    if not archive_path.is_file():
        request = urllib.request.Request(manifest['archive_url'], headers={'User-Agent': 'Thru3D-MVC-research'})
        with urllib.request.urlopen(request, timeout=45) as response:
            archive = response.read(manifest['archive_bytes'] + 1)
    else:
        archive = archive_path.read_bytes()
    if len(archive) != manifest['archive_bytes'] or hashlib.sha256(archive).hexdigest() != manifest['archive_sha256']:
        raise ValueError('MVC archive size or SHA256 differs from the pinned upstream revision')
    if not archive_path.is_file():
        archive_path.write_bytes(archive)
    prefix = 'edge264-mvc-' + manifest['revision']
    source = cache / prefix
    verified = 0
    with tarfile.open(archive_path, 'r:gz') as tar:
        for member in tar.getmembers():
            path = PurePosixPath(member.name)
            if path.is_absolute() or '..' in path.parts or not path.parts or path.parts[0] != prefix:
                raise ValueError('Unexpected upstream archive path')
            if not member.isfile():
                continue
            if len(path.parts) < 2:
                continue
            relative = PurePosixPath(*path.parts[1:])
            if relative.parts[0] != 'src' and str(relative) not in {
                'edge264mvc.h', 'LICENSE_BSD.txt', 'Makefile', 'CMakeLists.txt', 'README.md', 'DESIGN.md'
            }:
                continue
            target = source.joinpath(*relative.parts)
            if not target.resolve().is_relative_to(cache.resolve()):
                raise ValueError('MVC source cache escapes its temporary directory')
            content = tar.extractfile(member).read()
            if target.is_file() and target.read_bytes() != content:
                raise ValueError('Modified cached MVC source; preserve it before refreshing: ' + str(relative))
            if not target.is_file():
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(content)
            verified += 1
    if not (source / 'src/edge264mvc.c').is_file() or not (source / 'edge264mvc.h').is_file():
        raise ValueError('Required MVC source is missing')
    print(json.dumps({'source_dir': source.as_posix(), 'revision': manifest['revision'],
                      'archive_sha256': manifest['archive_sha256'], 'verified_source_files': verified}))


if __name__ == '__main__':
    main()
