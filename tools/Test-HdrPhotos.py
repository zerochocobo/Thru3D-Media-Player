"""Compare Android production HDR/EXR pixels with independent Python OpenEXR and numeric references.

Needs NumPy, Pillow, OpenEXR. Does not use user media/accounts. Temporary device fixtures are removed.
"""
import argparse
import json
import subprocess
import uuid
from pathlib import Path
import numpy as np
import OpenEXR


def mapped(rgb):
    rgb = np.asarray(rgb, dtype=np.float64)
    lum = np.maximum(rgb[::128, ::128], 0) @ np.array([.2126, .7152, .0722])
    good = np.isfinite(lum)
    exposure = np.clip(.18 / np.exp(np.log(np.maximum(lum[good], 1e-6)).mean()), 1e-6, 1e6) if good.any() else 1
    x = np.clip(np.nan_to_num(rgb, nan=0, posinf=1e20, neginf=0), 0, 1e20) * exposure
    y = np.clip(x * (2.51*x + .03) / (x*(2.43*x + .59) + .14), 0, 1)
    y = np.where(y <= .0031308, y*12.92, 1.055*np.power(y, 1/2.4)-.055)
    return np.concatenate((np.floor(y*255+.5).astype('uint8'), np.full((*y.shape[:2], 1), 255, dtype='uint8')), axis=-1)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--serial', required=True)
    p.add_argument('--adb', default='adb')
    p.add_argument('--probe', default='build/hdr-native/hdr_probe')
    p.add_argument('--output', default='build/output/hdr-photos/pixels')
    args = p.parse_args()
    root = Path(args.output); root.mkdir(parents=True, exist_ok=True)
    remote = '/data/local/tmp/thru-hdr-pixels-' + uuid.uuid4().hex
    adb = [args.adb, '-s', args.serial]
    def run(*c): return subprocess.run(adb+list(c), check=True, capture_output=True)
    results = []
    y, x = np.indices((70, 111)); rgb = np.stack((.01+x*.03, .1+y*.04, .02+(x+y)*.02), axis=-1).astype('float32')
    fixtures = []
    compressions = ['NO', 'RLE', 'ZIPS', 'ZIP', 'PIZ', 'PXR24', 'B44', 'B44A', 'DWAA', 'DWAB']
    for compression in compressions:
        for dtype in ['float16', 'float32']:
            path = root / f'{compression}-{dtype}.exr'
            OpenEXR.File({'compression': getattr(OpenEXR, compression+'_COMPRESSION')}, {c: rgb[:, :, i].astype(dtype) for i, c in enumerate('RGB')}).write(str(path))
            with OpenEXR.File(str(path), separate_channels=True) as f:
                ref = np.stack([f.channels()[c].pixels for c in 'RGB'], axis=-1)
            fixtures.append((path, mapped(ref)))
    tile = OpenEXR.TileDescription(); tile.xSize=32; tile.ySize=16
    for name, header, channels in [
        ('tiled', {'type':OpenEXR.tiledimage,'tiles':tile,'compression':OpenEXR.ZIP_COMPRESSION}, {c:rgb[:,:,i].astype('float16') for i,c in enumerate('RGB')}),
        ('offset-window', {'dataWindow':(np.array([-17,35],dtype='int32'),np.array([93,104],dtype='int32'))}, {c:rgb[:,:,i] for i,c in enumerate('RGB')}),
        ('layered', {}, {'beauty.'+c:np.ascontiguousarray(rgb[:,:,i]) for i,c in enumerate('RGB')}),
        ('gray', {}, {'Y':np.ascontiguousarray(rgb[:,:,0])})
    ]:
        path=root/(name+'.exr'); OpenEXR.File(header,channels).write(str(path))
        with OpenEXR.File(str(path),separate_channels=True) as f:
            ch=f.channels(); names=['Y']*3 if name=='gray' else [('beauty.' if name=='layered' else '')+c for c in 'RGB']
            reference=np.stack([ch[c].pixels for c in names],axis=-1)
        fixtures.append((path,mapped(reference)))
    multipart=root/'multipart.exr'
    OpenEXR.File([OpenEXR.Part({}, {'Z':np.ascontiguousarray(rgb[:,:,0])}, 'depth'),OpenEXR.Part({}, {c:np.ascontiguousarray(rgb[:,:,i]) for i,c in enumerate('RGB')}, 'color')]).write(str(multipart))
    fixtures.append((multipart,mapped(rgb)))
    # Old flat RGBE, modern per-channel RLE, all axis signs and transposed storage.
    yy, xx = np.indices((70, 111))
    rgbe = np.stack((20+xx % 110, 30+yy % 90, 60+(xx+yy) % 120, np.full_like(xx, 130)), axis=-1).astype('uint8')
    ref = mapped(rgbe[:, :, :3].astype('float32') * .015625)
    for a, b in [('-Y', '+X'), ('+Y', '-X'), ('+X', '-Y'), ('-X', '+Y')]:
        for rle in [False, True]:
            path = root/f'rgbe-{a}-{b}-{rle}.hdr'
            first, second = (70, 111) if a[1] == 'Y' else (111, 70)
            stored = rgbe if a[1] == 'Y' else np.transpose(rgbe, (1, 0, 2))
            if (a[0] == '+' if a[1] == 'Y' else a[0] == '-'): stored = stored[::-1]
            if (b[0] == '+' if b[1] == 'Y' else b[0] == '-'): stored = stored[:, ::-1]
            with path.open('wb') as out:
                out.write(f'#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n{a} {first} {b} {second}\n'.encode())
                for row in stored:
                    if not rle: out.write(row.tobytes()); continue
                    out.write(bytes([2, 2, second >> 8, second & 255]))
                    for c in range(4): out.write(bytes([second]) + row[:, c].tobytes())
            fixtures.append((path, ref))
    try:
        run('shell', 'mkdir', '-p', remote)
        run('push', str(Path(args.probe).resolve()), remote+'/probe'); run('shell', 'chmod', '700', remote+'/probe')
        for path, reference in fixtures:
            run('push', str(path.resolve()), remote+'/source')
            for sample in [1, 3]:
                result = run('shell', remote+'/probe', remote+'/source', remote+'/pixels', str(sample)).stdout.decode().strip()
                data = run('exec-out', 'cat', remote+'/pixels').stdout
                target = reference[::sample, ::sample]
                image = np.frombuffer(data, 'uint8').reshape(target.shape)
                error = np.abs(image.astype('int16')-target.astype('int16'))
                check = {'file': path.name, 'sample': sample, 'max_error': int(error.max()), 'mae': float(error.mean()), 'native': result}
                results.append(check); print(json.dumps(check), flush=True)
                assert error.max() <= 1, check
        bad = root/'truncated.hdr'; bad.write_bytes(b'#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y 8000 +X 16000\n')
        run('push', str(bad.resolve()), remote+'/source')
        assert subprocess.run(adb+['shell', remote+'/probe', remote+'/source', remote+'/pixels', '8'], capture_output=True).returncode != 0
        bad.write_bytes(b'#?RADIANCE\n'+b'x'*70000+b'\n')
        run('push', str(bad.resolve()), remote+'/source')
        assert subprocess.run(adb+['shell', remote+'/probe', remote+'/source', remote+'/pixels', '8'], capture_output=True).returncode != 0
        report = {'checks': len(results)+2, 'failures': 0, 'results': results}
        (root/'report.json').write_text(json.dumps(report, indent=2), encoding='utf8')
        print('HDR/EXR pixels:', report['checks'], 'checks, 0 failures')
    finally:
        # Exact UUID-named directory created above, contains only this test's fixtures.
        subprocess.run(adb+['shell', 'rm', '-rf', remote], check=True)


if __name__ == '__main__': main()
