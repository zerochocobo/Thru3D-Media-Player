"""Build a deterministic, compact offline index; no runtime downloads or user data.

Data: rime/rime-pinyin-simp (Apache-2.0). See third_party/pinyin_simp/NOTICE.md.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE_HASH = "e341598343a0f0f2035bb1aafc34a7f3bb7887deeecb3f60796262aaa2983e6b"


def build():
    source = ROOT / "third_party/pinyin_simp/pinyin_simp.dict.yaml"
    raw = source.read_bytes()
    # Git may check text out with CRLF; source identity is the upstream LF bytes.
    if hashlib.sha256(raw.replace(b"\r\n", b"\n")).hexdigest() != SOURCE_HASH:
        raise ValueError("Pinyin source checksum mismatch")
    entries = {}
    for line in raw.decode("utf-8").splitlines():
        if "\t" not in line or line.startswith("#"):
            continue
        word, reading, weight = line.split("\t")
        reading = reading.lower().replace(" ", "'")
        if not re.fullmatch("[a-z]+(?:'[a-z]+)*", reading):
            raise ValueError("Invalid pinyin reading")
        entries[(reading, word)] = int(weight)
    overrides = json.loads((ROOT / "app/godot/input/pinyin_overrides.json").read_text("utf-8"))
    for item in overrides:
        entries[(item[0], item[1])] = item[2]
    groups = {}
    for (reading, word), weight in entries.items():
        groups.setdefault(reading.replace("'", ""), []).append((reading, word, weight))
    keys = sorted(groups)
    offsets = [0]
    blocks = []
    for key in keys:
        block = "".join(f"{reading}\t{word}\n" for reading, word, _ in
                        sorted(groups[key], key=lambda entry: (-entry[2], entry[1], entry[0]))).encode("utf-8")
        blocks.append(block)
        offsets.append(offsets[-1] + len(block))
    files = {"pinyin.keys": ("\n".join(keys)).encode("ascii"),
             "pinyin.offsets": struct.pack("<" + "I" * len(offsets), *offsets),
             "pinyin.words": b"".join(blocks)}
    manifest = {"format": 1, "source_sha256": SOURCE_HASH, "entries": len(entries), "keys": len(keys),
                "files": {name: {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
                          for name, data in files.items()}}
    files["pinyin_manifest.json"] = (json.dumps(manifest, indent=2) + "\n").encode("utf-8")
    return files


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--archive", type=Path)
    args = parser.parse_args()
    for name, data in build().items():
        path = ROOT / "app/godot/input" / name
        if args.check:
            actual = path.read_bytes()
            if name.endswith(".json") or name.endswith(".keys"):
                actual = actual.replace(b"\r\n", b"\n")
            if actual != data:
                raise ValueError(f"Stale or missing lexicon: {name}")
        else:
            path.write_bytes(data)
    if args.archive:
        with zipfile.ZipFile(args.archive) as archive:
            prefix = "assets/" if args.archive.suffix.lower() == ".apk" else ""
            for name, data in build().items():
                if archive.read(prefix + "input/" + name) != data:
                    raise ValueError(f"Packaged lexicon differs: {name}")
            for name in ["LICENSE.txt", "AUTHORS.txt", "NOTICE.txt"]:
                if archive.read(prefix + "input/" + name) != (ROOT / "app/godot/input" / name).read_bytes():
                    raise ValueError(f"Packaged dictionary notice differs: {name}")
    print("Chinese lexicon: verified" if args.check else "Chinese lexicon: generated")
