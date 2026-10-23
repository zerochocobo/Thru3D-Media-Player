"""Turns downloaded CC0 PBR sets into calibrated, unlit-ready cinema textures.

python -I tools/cinema/prepare_textures.py [RAW_DIR]   (default tmp/textures/raw)

Unlit rendering cannot use normal maps at runtime, so each output bakes the
scanned colour, ambient occlusion and the normal map's micro-relief (lit from
the screen side) into one albedo. The mean linear albedo is then calibrated
to a dark auditorium finish while keeping the scan's hue and detail.
Outputs land in tools/cinema/textures/ with a manifest of sources and licences.
"""
import json
import os
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
RAW = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "..", "tmp", "textures", "raw"))
OUT = os.path.join(HERE, "textures")

# name: source asset, output size, metres per repeat, target mean linear albedo,
#       saturation keep (1 = scan colour), optional tint applied to luminance, relief strength.
TEXTURES = {
    "carpet_floor": dict(asset="Carpet006", size=1024, tile=1.0, albedo=0.030, saturation=0.55, relief=0.5),
    "carpet_tread": dict(asset="Carpet016", size=1024, tile=0.8, albedo=0.026, tint=(0.80, 0.86, 1.0), relief=0.6),
    "wall_fabric": dict(asset="Fabric039", size=1024, tile=0.6, albedo=0.032, tint=(0.88, 0.92, 1.0), relief=0.7),
    "velvet_black": dict(asset="Fabric042", size=1024, tile=0.5, albedo=0.007, saturation=0.3, relief=0.5),
    "cloud_felt": dict(asset="Fabric030", size=1024, tile=1.0, albedo=0.020, tint=(0.92, 0.94, 1.0), relief=0.6),
    "wood_walnut": dict(asset="Wood051", size=1024, tile=0.8, albedo=0.060, saturation=1.0, relief=0.35),
    "metal_brushed": dict(asset="Metal009", size=1024, tile=0.6, albedo=0.110, saturation=0.2, relief=0.3),
    # Seat inputs stay at 2048: they are baked into the chair atlas, not tiled at runtime.
    "seat_velour": dict(asset="Fabric063", size=2048, tile=0.35, albedo=0.040, tint=(1.0, 0.16, 0.22), relief=0.9),
    "seat_leather": dict(asset="Leather030", size=2048, tile=0.45, albedo=0.018, saturation=0.9, relief=0.7),
    "seat_shell": dict(asset="Plastic011", size=2048, tile=0.5, albedo=0.010, saturation=0.2, relief=0.4),
    "seat_metal": dict(asset="Metal009", size=2048, tile=0.4, albedo=0.040, saturation=0.2, relief=0.3),
}
SOURCES = {
    "ph": ("Poly Haven", "https://polyhaven.com/a/%s", "CC0 1.0"),
    "acg": ("ambientCG", "https://ambientcg.com/a/%s", "CC0 1.0"),
}
# Relief light: from above and slightly towards the viewer, like screen spill.
LIGHT = np.array([0.0, 0.55, 0.835])


def srgb_to_linear(c):
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(c):
    c = np.clip(c, 0.0, 1.0)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * np.power(c, 1 / 2.4) - 0.055)


def find(folder, *keys):
    for name in sorted(os.listdir(folder)):
        lower = name.lower()
        if any(key in lower for key in keys):
            return os.path.join(folder, name)
    return None


def load(path, size, mode="RGB"):
    image = Image.open(path).convert(mode)
    if image.size != (size, size):
        image = image.resize((size, size), Image.LANCZOS)
    return np.asarray(image, dtype=np.float64) / 255.0


def process(name, spec):
    asset = spec["asset"]
    folder = os.path.join(RAW, asset.replace(":", "_"))
    size = spec["size"]
    colour = srgb_to_linear(load(find(folder, "_color", "diffuse"), size))
    ao_path = find(folder, "ambientocclusion", "_ao")
    if ao_path:
        colour *= load(ao_path, size, "L")[..., None] ** 0.8
    normal_path = find(folder, "normalgl", "nor_gl")
    if normal_path:
        normal = load(normal_path, size) * 2.0 - 1.0
        normal /= np.linalg.norm(normal, axis=2, keepdims=True) + 1e-6
        shade = 1.0 + spec["relief"] * (normal @ LIGHT - LIGHT[2])
        colour *= np.clip(shade, 0.35, 1.6)[..., None]
    luminance = colour @ np.array([0.2126, 0.7152, 0.0722])
    if "tint" in spec:
        colour = luminance[..., None] * np.array(spec["tint"])
    else:
        keep = spec.get("saturation", 1.0)
        colour = luminance[..., None] + (colour - luminance[..., None]) * keep
    colour *= spec["albedo"] / max(1e-6, float(colour.mean()))
    Image.fromarray((linear_to_srgb(colour) * 255.0 + 0.5).astype(np.uint8)).save(
        os.path.join(OUT, name + ".jpg"), quality=92, optimize=True)
    site, url, licence = SOURCES["ph" if asset.startswith("ph:") else "acg"]
    asset_id = asset.split(":")[-1]
    return {"file": name + ".jpg", "size": size, "tile_metres": spec["tile"], "mean_linear_albedo": spec["albedo"],
            "source": site, "asset": asset_id, "url": url % asset_id, "license": licence}


def main():
    os.makedirs(OUT, exist_ok=True)
    manifest = {}
    for name, spec in TEXTURES.items():
        manifest[name] = process(name, spec)
        print("texture", name, manifest[name]["asset"])
    with open(os.path.join(OUT, "textures.json"), "w", encoding="utf-8", newline="\n") as handle:
        json.dump(manifest, handle, indent=1, sort_keys=True)
        handle.write("\n")


if __name__ == "__main__":
    main()
