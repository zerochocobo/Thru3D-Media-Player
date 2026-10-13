"""Reproduce the small, explicitly licensed menu bracket font (requires fontTools)."""
from hashlib import sha256
from pathlib import Path
from urllib.request import urlopen

from fontTools import subset
from fontTools.ttLib import TTFont

ROOT = Path(__file__).resolve().parents[2]
BASE = "https://raw.githubusercontent.com/notofonts/noto-cjk/Sans2.004/"
SOURCE = "Sans/OTF/SimplifiedChinese/NotoSansCJKsc-Regular.otf"
SOURCE_SHA256 = "2c76254f6fc379fddfce0a7e84fb5385bb135d3e399294f6eeb6680d0365b74b"
LICENSE_SHA256 = "6a73f9541c2de74158c0e7cf6b0a58ef774f5a780bf191f2d7ec9cc53efe2bf2"
CHARACTERS = "【】「」『』〔〕〈〉《》〖〗〘〙〚〛（）［］｛｝"


def fetch(relative: str, expected: str) -> bytes:
    data = urlopen(BASE + relative, timeout=45).read()
    if sha256(data).hexdigest() != expected:
        raise ValueError("Pinned font source/license hash changed: " + relative)
    return data


def main() -> None:
    cache = ROOT / "tmp/font-feedback"
    cache.mkdir(parents=True, exist_ok=True)
    source = cache / "NotoSansCJKsc-Regular.otf"
    source.write_bytes(fetch(SOURCE, SOURCE_SHA256))
    license_text = fetch("LICENSE", LICENSE_SHA256)
    font = TTFont(source)
    options = subset.Options()
    options.name_IDs = ["*"]
    options.name_legacy = True
    options.name_languages = ["*"]
    worker = subset.Subsetter(options=options)
    worker.populate(text=CHARACTERS)
    worker.subset(font)
    for item in font["name"].names:
        if item.nameID in [1, 4, 6, 16]:
            value = "Thru3D-CJK-Punctuation" if item.nameID == 6 else "Thru3D CJK Punctuation"
            item.string = value.encode(item.getEncoding())
    cff = font["CFF "].cff
    cff.fontNames = ["Thru3D-CJK-Punctuation"]
    cff.topDictIndex[0].FamilyName = "Thru3D CJK Punctuation"
    cff.topDictIndex[0].FullName = "Thru3D CJK Punctuation"
    output = ROOT / "app/godot/assets/fonts"
    output.mkdir(parents=True, exist_ok=True)
    font.save(output / "cjk-brackets.otf")
    (output / "LICENSE.txt").write_bytes(license_text)
    print("CJK bracket subset:", (output / "cjk-brackets.otf").stat().st_size, "bytes")


if __name__ == "__main__":
    main()
