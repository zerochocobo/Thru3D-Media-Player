"""Prepare CC0 scan inputs for the local lighting study, without painted light/AO.

Uses the previously downloaded, reproducible ambientCG cache. Generated inputs
live beside this script in sample/textures, not in the disposable cache.
"""
import hashlib
import json
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(__file__).parent / 'sample/textures'
SPECS = {
    'velour': ('Fabric063', (0.060, 0.007, 0.014), 0.35),
    'leather': ('Leather030', (0.022, 0.015, 0.011), 0.45),
    'shell': ('Plastic011', (0.026, 0.030, 0.035), 0.5),
    'carpet': ('Carpet006', (0.055, 0.048, 0.041), 1.0),
    'wall': ('Fabric039', (0.070, 0.067, 0.061), 0.6),
    'wood': ('Wood051', (0.105, 0.054, 0.024), 0.8),
}


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
            im.save(dest, quality=95)
        records[name] = record
    (OUT / 'sources.json').write_text(json.dumps(records, indent=2) + '\n', encoding='utf8')


if __name__ == '__main__':
    main()
