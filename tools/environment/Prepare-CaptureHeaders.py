"""Export only the public FFmpeg headers used by the capture bridge, from the existing pin."""
import argparse
import hashlib
import json
import re
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--archive", type=Path, required=True)
    args = parser.parse_args()
    pin = next(x for x in json.loads((ROOT / "third_party/mpv/source-lock.json").read_text())["sources"] if x["name"] == "ffmpeg")
    assert hashlib.sha256(args.archive.read_bytes()).hexdigest() == pin["sha256"], "FFmpeg source archive differs"
    destination = ROOT / "native/mpv/include/ffmpeg"
    with tarfile.open(args.archive) as archive:
        members = {m.name.partition("/")[2]: m for m in archive.getmembers() if m.isfile()}
        todo = ["libavformat/avformat.h", "libavutil/opt.h", "libavutil/mathematics.h"]
        exported = {}
        while todo:
            name = todo.pop()
            if name in exported:
                continue
            if name == "libavutil/avconfig.h":
                content = b"/* ARM64 Android public-header configuration. */\n#define AV_HAVE_BIGENDIAN 0\n#define AV_HAVE_FAST_UNALIGNED 1\n"
            else:
                content = archive.extractfile(members[name]).read()
            exported[name] = hashlib.sha256(content).hexdigest()
            target = destination / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(content)
            for include in re.findall(rb'#\s*include\s+"([^"]+)"', content):
                value = include.decode()
                dependency = value if value.startswith("libav") else str(Path(name).parent / value).replace("\\", "/")
                if dependency in members or dependency == "libavutil/avconfig.h":
                    todo.append(dependency)
        (destination / "COPYING.LGPLv2.1").write_bytes(archive.extractfile(members["COPYING.LGPLv2.1"]).read())
    manifest = {"revision": pin["revision"], "archive_sha256": pin["sha256"], "headers": dict(sorted(exported.items()))}
    (destination / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Exported {len(exported)} pinned public headers")


if __name__ == "__main__":
    main()
