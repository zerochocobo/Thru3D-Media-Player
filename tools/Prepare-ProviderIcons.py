"""Rebuild the transparent provider SVGs from the retained vector sources.

Sources and modification notes: third_party/provider-icons/SOURCES.md.
No network or raster/image-generation dependency is needed.
"""
from pathlib import Path
import copy
import re
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "third_party/provider-icons"
OUTPUT = ROOT / "app/godot/assets/provider-icons"
NS = "http://www.w3.org/2000/svg"
ET.register_namespace("", NS)

# Visible geometry, rather than application tile backgrounds, determines the size.
BOUNDS = {
    "115": (9, 6, 18, 24), "emby": (0, 0, 24, 24),
    "jellyfin": (0, 0, 72, 72), "plex": (148, 70, 216, 372),
    "stash": (48, 70, 160, 114), "onedrive": (0, 94, 512, 324),
    "baidu": (2, 6, 44, 36), "aliyun": (1, 2, 46, 44),
    "quark": (2, 6, 44, 36), "xbvr": (0, 0, 444, 123),
    "webdav": (1, 1, 22, 22),
}


def rebuild(name, bounds):
    source = ET.parse(SOURCE / (name + ".svg")).getroot()
    # Expand the three line-art styles before discarding editor/style metadata.
    outlined = name in {"baidu", "aliyun", "quark"}
    for parent in source.iter():
        for child in list(parent):
            tag = child.tag.split("}")[-1]
            if tag in {"metadata", "namedview", "title", "defs"}:
                parent.remove(child)
            elif name in {"115", "stash"} and tag == "rect":
                parent.remove(child)
    for element in source.iter():
        element.tag = element.tag.split("}")[-1]
        attributes = {}
        for key, value in element.attrib.items():
            if "}" not in key and key not in {"id", "class", "style", "filter", "clip-path", "role"}:
                attributes[key] = value
        if not outlined:
            style = dict(re.findall(r"([\w-]+)\s*:\s*([^;]+)", element.get("style", "")))
            for key in ["fill", "fill-rule", "opacity", "fill-opacity"]:
                if key in style:
                    attributes[key] = style[key]
            if attributes.get("fill", "none") != "none":
                attributes["fill"] = "white"
        element.attrib.clear()
        element.attrib.update(attributes)
    if name == "plex":
        # The collection source cuts the chevron out of a solid app tile.
        # Preserve that exact inner path as a positive, transparent-background mark.
        source.clear()
        ET.SubElement(source, "path", {"d": "M256 442H148l108-186L148 70h108l108 186z"})
    x, y, width, height = bounds
    scale = 104 / max(width, height)
    svg = ET.Element("svg", {"xmlns": NS, "width": "128", "height": "128", "viewBox": "0 0 128 128"})
    group = ET.SubElement(svg, "g", {
        "transform": f"translate({64 - width * scale / 2:.6f} {64 - height * scale / 2:.6f}) scale({scale:.6f}) translate({-x} {-y})",
        "fill": "none" if outlined or name == "webdav" else "white",
    })
    if outlined:
        group.attrib.update({"stroke": "white", "stroke-width": "2.6", "stroke-linecap": "round", "stroke-linejoin": "round"})
    elif name == "webdav":
        group.attrib.update({"stroke": "white", "stroke-width": "1.7", "stroke-linecap": "round", "stroke-linejoin": "round"})
    for element in source:
        group.append(copy.deepcopy(element))
    OUTPUT.mkdir(parents=True, exist_ok=True)
    (OUTPUT / (name + ".svg")).write_text(ET.tostring(svg, encoding="unicode") + "\n", encoding="utf-8")


if __name__ == "__main__":
    for name, bounds in BOUNDS.items():
        rebuild(name, bounds)
    notice = (SOURCE / "SOURCES.md").read_text(encoding="utf-8")
    for license_file in sorted(SOURCE.glob("LICENSE-*.txt")):
        notice += "\n\n" + license_file.name + "\n\n" + license_file.read_text(encoding="utf-8")
    (ROOT / "third_party/player-licenses/provider-icons.txt").write_text(notice, encoding="utf-8")
    print(f"Prepared {len(BOUNDS)} transparent provider icons in {OUTPUT}")
