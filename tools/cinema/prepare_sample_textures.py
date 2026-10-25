"""Prepare CC0 scan inputs for the local lighting study, without painted light/AO.

Uses the previously downloaded, reproducible ambientCG cache. Generated inputs
live beside this script in sample/textures, not in the disposable cache.
"""
import hashlib
import json
import os
import time
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(__file__).parent / 'sample/textures'
SPECS = {
    'velour': ('Fabric063', (0.060, 0.007, 0.014), 0.35),
    'leather': ('Leather030', (0.022, 0.015, 0.011), 0.45),
    'shell': ('Plastic011', (0.026, 0.030, 0.035), 0.5),
    # Plain dark cut pile: a large regular pattern reads as a repeating game tile.
    'carpet': ('Carpet013', (0.025, 0.022, 0.021), 0.6),
    # Dark warm grey: a pale wall made the lit hall read as a conference room.
    'wall': ('Fabric039', (0.038, 0.035, 0.032), 0.6),
    # Dark walnut veneer; the earlier target turned the scan orange.
    'wood': ('Wood051', (0.050, 0.031, 0.020), 0.6),
}


def _save(image, dest):
    """Writes beside the target and swaps it in. A just-written scan can stay
    briefly locked by real-time file scanning; retry instead of failing."""
    temp = dest.with_name(dest.stem + '.part.jpg')
    image.save(temp, quality=95)
    for attempt in range(20):
        try:
            os.replace(temp, dest)
            return
        except OSError:
            time.sleep(.5)
    raise OSError('Could not replace ' + str(dest))


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    records = {}
    for name, (asset, target, tile) in SPECS.items():
        folder = ROOT / 'tmp/textures/raw' / asset
        record = {'source': 'https://ambientcg.com/a/' + asset, 'license': 'CC0 1.0',
                  'tile_metres': tile, 'target_linear_rgb': target, 'inputs': {}}
        for channel in ['Color', 'Displacement', 'Roughness']:
            source = next(folder.glob('*_' + channel + '.jpg'))
            record['inputs'][channel] = {'name': source.name, 'sha256': hashlib.sha256(source.read_bytes()).hexdigest()}
            im = Image.open(source).resize((1024, 1024), Image.Resampling.LANCZOS)
            if channel == 'Color':
                rgb = np.asarray(im.convert('RGB'), dtype=np.float32) / 255
                linear = np.where(rgb <= .04045, rgb / 12.92, ((rgb + .055) / 1.055) ** 2.4)
                lum = linear @ np.array([.2126, .7152, .0722])
                # Keep scan variation; remove no shadows by guesswork and add no fake relief.
                contrast = {'shell': .16, 'carpet': .35, 'wood': .45, 'velour': .55}.get(name, .7)
                variation = 1 + (lum / max(float(lum.mean()), 1e-5) - 1) * contrast
                record['scan_contrast'] = contrast
                linear = np.clip(variation[..., None] * target, 0, .8)
                srgb = np.where(linear <= .0031308, linear * 12.92, 1.055 * linear ** (1 / 2.4) - .055)
                im = Image.fromarray(np.uint8(np.clip(srgb * 255 + .5, 0, 255)))
            else:
                im = im.convert('L')
            dest = OUT / (name + '_' + channel.lower() + '.jpg')
            _save(im, dest)
        records[name] = record
    (OUT / 'sources.json').write_text(json.dumps(records, indent=2) + '\n', encoding='utf8')


if __name__ == '__main__':
    main()
