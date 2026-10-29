"""Verify and prepare pinned LGPL Blu-ray/UDF source in the temporary cache."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[2]


def main(kind='bluray'):
    lock = json.loads((ROOT / f'third_party/{kind}/source-lock.json').read_text())
    cache = ROOT / f'tmp/{kind}-sources'
    cache.mkdir(parents=True, exist_ok=True)
    sources = {}
    for record in lock['libraries']:
        archive = cache / record['archive']
        if not archive.is_file():
            with urllib.request.urlopen(record['url'], timeout=45) as response:
                data = response.read(record['bytes'] + 1)
        else:
            data = archive.read_bytes()
        if len(data) != record['bytes'] or hashlib.sha256(data).hexdigest() != record['sha256']:
            raise ValueError('Blu-ray source archive differs: ' + record['name'])
        if not archive.is_file():
            archive.write_bytes(data)
        source = cache / (record['name'] + '-' + record['version'])
        with tarfile.open(archive) as tar:
            for member in tar.getmembers():
                path = PurePosixPath(member.name)
                if path.is_absolute() or '..' in path.parts or path.parts[0] != source.name:
                    raise ValueError('Blu-ray archive path is unsafe')
                if not member.isfile():
                    continue
                target = cache.joinpath(*path.parts)
                if not target.resolve().is_relative_to(cache.resolve()):
                    raise ValueError('Blu-ray source cache escapes its temporary directory')
                content = tar.extractfile(member).read()
                if target.is_file() and target.read_bytes() != content:
                    raise ValueError('Modified upstream source; preserve it before refreshing: ' + member.name)
                if not target.is_file():
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(content)
        sources[record['name']] = source.as_posix()
    print(json.dumps(sources))


if __name__ == '__main__':
    main()
