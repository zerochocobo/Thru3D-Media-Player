"""Prepare the shipped 8K sky from the verified Poly Haven 16K EXR.

Uses the viewer's global-logmean-aces-srgb-v1 display conversion, then FFmpeg
Lanczos downsampling and 4:4:4 JPEG encoding. Requires OpenEXR and NumPy.
Source photos and scratch PPM belong in tmp/, never in the APK.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

import numpy as np
import OpenEXR


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--scratch', type=Path, default=Path('tmp/sky-background'))
    parser.add_argument('--ffmpeg', default='ffmpeg')
    args = parser.parse_args()
    with args.source.open('rb') as stream:
        digest = hashlib.file_digest(stream, 'md5').hexdigest()
    if digest != 'df39600195a70a7d6464b109222a111b':
        raise ValueError('Expected the verified kloppenheim_06_puresky 16K EXR')
    args.scratch.mkdir(parents=True, exist_ok=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    ppm = args.scratch / 'kloppenheim-tonemapped.ppm'
    try:
        with OpenEXR.File(str(args.source), separate_channels=True) as source:
            channels = source.channels()
            rgb = [channels[c].pixels for c in 'RGB']
            assert all(c.shape == (8192, 16384) for c in rgb)
            luminance = sum(c[::128, ::128].astype('float64') * weight
                            for c, weight in zip(rgb, [.2126, .7152, .0722]))
            exposure = float(np.clip(.18 / np.exp(np.log(np.maximum(luminance, 1e-6)).mean()), 1e-6, 1e6))
            linear = np.arange(65536, dtype='float64') / 65535
            srgb = np.where(linear <= .0031308, linear * 12.92, 1.055 * linear ** (1/2.4) - .055)
            transfer = np.floor(srgb * 255 + .5).astype('uint8')
            with ppm.open('wb') as output:
                output.write(b'P6\n16384 8192\n255\n')
                for top in range(0, 8192, 32):
                    block = np.stack([c[top:top+32] for c in rgb], axis=-1).astype('float64')
                    block = np.clip(np.nan_to_num(block, nan=0, posinf=1e20, neginf=0), 0, 1e20) * exposure
                    mapped = np.clip(block * (2.51*block + .03) / (block*(2.43*block + .59) + .14), 0, 1)
                    output.write(transfer[np.floor(mapped*65535 + .5).astype('int32')].tobytes())
        subprocess.run([args.ffmpeg, '-hide_banner', '-loglevel', 'error', '-y',
                        '-i', str(ppm), '-vf', 'scale=8192:4096:flags=lanczos',
                        '-frames:v', '1', '-q:v', '2', '-pix_fmt', 'yuvj444p',
                        '-update', '1', str(args.output)], check=True)
        with args.output.open('rb') as stream:
            output_sha256 = hashlib.file_digest(stream, 'sha256').hexdigest()
        print(json.dumps({'source_md5': digest, 'exposure': exposure,
                          'size': [8192, 4096], 'bytes': args.output.stat().st_size,
                          'sha256': output_sha256}))
    finally:
        ppm.unlink(missing_ok=True)


if __name__ == '__main__':
    main()
