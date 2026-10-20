"""Exercise the production TIFF core on an Android device, using independent Pillow/NumPy references."""
import argparse
import json
from pathlib import Path
import re
import subprocess

import numpy as np
from PIL import Image, TiffImagePlugin
import tifffile


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--adb', default='adb')
    p.add_argument('--serial', required=True)
    p.add_argument('--probe', default='build/tiff-native/tiff_probe')
    p.add_argument('--real', default='tmp/tiff-support/noirlab-20k-original.tif')
    p.add_argument('--output', default='build/output/tiff-support/pixels')
    args = p.parse_args()
    out = Path(args.output).resolve(); out.mkdir(parents=True, exist_ok=True)
    # All files here are synthetic or reproducible public samples, never user media.
    remote = '/data/local/tmp/thru-tiff-check-20261020'

    def adb(*command, check=True):
        return subprocess.run([args.adb, '-s', args.serial, *map(str, command)], text=True,
                              capture_output=True, check=check)

    adb('shell', 'mkdir', '-p', remote)
    adb('push', Path(args.probe).resolve(), remote + '/tiff_probe')
    adb('shell', 'chmod', '700', remote + '/tiff_probe')
    yy, xx = np.indices((333, 641))
    rgb = np.stack(((xx * 7 + yy) % 256, (yy * 11 + xx) % 256, (xx * 3 + yy * 13) % 256), axis=-1).astype('uint8')
    fixtures = []
    for compression in ['raw', 'tiff_lzw', 'packbits', 'tiff_adobe_deflate', 'jpeg']:
        file = out / (compression + '.tif')
        Image.fromarray(rgb).save(file, compression=compression)
        reference = np.array(Image.open(file).convert('RGBA'))
        fixtures.append((file, reference, 3 if compression == 'jpeg' else 0))
    for name, data, options in [
        ('rgb16', rgb.astype('uint16') * 257, {'photometric': 'rgb'}),
        ('big-endian16', rgb.astype('uint16') * 257, {'photometric': 'rgb', 'byteorder': '>'}),
        ('bigtiff', rgb, {'photometric': 'rgb', 'bigtiff': True}),
        ('tiled16', rgb.astype('uint16') * 257, {'photometric': 'rgb', 'tile': (64, 64), 'compression': 'deflate'}),
        ('planar16', np.moveaxis(rgb.astype('uint16') * 257, 2, 0), {'photometric': 'rgb', 'planarconfig': 'separate'}),
    ]:
        file = out / (name + '.tiff'); tifffile.imwrite(file, data, **options)
        ref = np.dstack((rgb, np.full(rgb.shape[:2], 255, dtype='uint8')))
        fixtures.append((file, ref, 0))
    gray = ((xx * 91 + yy * 37) % 65536).astype('uint16')
    file = out / 'gray16.tif'; tifffile.imwrite(file, gray)
    gray8 = (gray >> 8).astype('uint8')
    fixtures.append((file, np.dstack((gray8, gray8, gray8, np.full(gray.shape, 255, dtype='uint8'))), 0))
    for mode in ['CMYK', 'RGBA', 'P']:
        file = out / (mode + '.tif')
        Image.fromarray(rgb).convert(mode).save(file, compression='tiff_lzw')
        fixtures.append((file, np.array(Image.open(file).convert('RGBA')), 1))
    file = out / 'orientation6.tif'
    tags = TiffImagePlugin.ImageFileDirectory_v2(); tags[274] = 6
    Image.fromarray(rgb).save(file, tiffinfo=tags, compression='raw')
    fixtures.append((file, np.dstack((rgb, np.full(rgb.shape[:2], 255, dtype='uint8'))), 0))
    reports = []

    def run(file, reference, tolerance, sample, left, top, width, height):
        target = remote + '/fixture.tif'
        adb('push', file, target)
        result = adb('shell', remote + '/tiff_probe', target, remote + '/result.rgba',
                     sample, left, top, width, height)
        raw = out / 'result.rgba'; adb('pull', remote + '/result.rgba', raw)
        actual = np.fromfile(raw, dtype='uint8').reshape((height + sample - 1) // sample,
                                                        (width + sample - 1) // sample, 4)
        expected = reference[top:top + height:sample, left:left + width:sample]
        error = np.abs(actual.astype('int16') - expected.astype('int16'))
        maximum = int(error.max())
        assert maximum <= tolerance, (file.name, sample, left, top, maximum)
        rss = int(re.search(r'maxrss_kb=(\d+)', result.stdout).group(1))
        assert rss < 196608, (file.name, rss)
        report = {'file': file.name, 'sample': sample, 'region': [left, top, width, height],
                  'max_error': maximum, 'mae': float(error.mean()), 'maxrss_kb': rss}
        reports.append(report)
        print(json.dumps(report), flush=True)

    for file, reference, tolerance in fixtures:
        run(file, reference, tolerance, 1, 17, 23, 299, 127)
        run(file, reference, tolerance, 3, 0, 0, 641, 333)
    # A compressed single strip larger than the decoded allocation budget must use scanlines.
    large = np.empty((1200,10000,3),dtype='uint16')
    large[:,:,0] = np.arange(10000,dtype='uint16')[None,:]*5
    large[:,:,1] = np.arange(1200,dtype='uint16')[:,None]*43
    large[:,:,2] = 30123
    file = out/'large-strip16-be.tiff'
    tifffile.imwrite(file,large,photometric='rgb',byteorder='>',compression='deflate',rowsperstrip=1200)
    rgb8=np.rint(large/257).astype('uint8')
    reference=np.dstack((rgb8,np.full(rgb8.shape[:2],255,dtype='uint8')))
    run(file,reference,0,1,17,23,299,127)
    run(file,reference,0,4,0,0,10000,1200)
    publication=Path('tmp/tiff-support/noirlab-10k.tif')
    if publication.is_file():
        reference=np.array(Image.open(publication).convert('RGBA'))
        run(publication,reference,0,4,0,0,10000,5000)
        target=remote+'/fixture.tif'
        result=adb('shell',remote+'/tiff_probe',target,remote+'/result.rgba',4,0,0,10000,5000,remote+'/cache.t3di')
        cached=out/'publication.t3di'; adb('pull',remote+'/cache.t3di',cached)
        assert cached.stat().st_size==200000016
        header=cached.read_bytes()[:16] if cached.stat().st_size<100 else None
        with cached.open('rb') as stream: header=stream.read(16)
        assert header[:4]==b'T3DI' and np.frombuffer(header[4:],dtype='<u4').tolist()==[10000,5000,1]
        pixels=np.memmap(cached,dtype='uint8',mode='r',offset=16,shape=(5000,10000,4))
        assert np.array_equal(pixels[2100:3128,4500:5528],reference[2100:3128,4500:5528])
        rss=int(re.search(r'maxrss_kb=(\d+)',result.stdout).group(1)); assert rss<196608
        reports.append({'file':'NOIRLab 10K large LZW strip and region cache','max_error':0,'maxrss_kb':rss})
    real = Path(args.real)
    if real.is_file():
        adb('push', real.resolve(), remote + '/noirlab.tif')
        source = tifffile.memmap(real)
        # No full 1.2 GB host decode is required for the independent reference.
        for left, top in [(9973, 4877), (0, 0), (18972, 8972)]:
            region = np.rint(source[top:top+1028, left:left+1028] / 257).astype('uint8')
            reference = np.dstack((region, np.full((1028, 1028), 255, dtype='uint8')))
            # Avoid pushing the GB sample for every region.
            result = adb('shell', remote + '/tiff_probe', remote + '/noirlab.tif', remote + '/result.rgba',
                         1, left, top, 1028, 1028)
            raw = out / 'result.rgba'; adb('pull', remote + '/result.rgba', raw)
            actual = np.fromfile(raw, dtype='uint8').reshape(1028, 1028, 4)
            assert np.array_equal(actual, reference), ('real original region mismatch', left, top)
            rss = int(re.search(r'maxrss_kb=(\d+)', result.stdout).group(1))
            assert rss < 196608
            reports.append({'file': 'NOIRLab 20K 16-bit RGB original', 'region': [left, top, 1028, 1028],
                            'max_error': 0, 'maxrss_kb': rss})
    (out / 'report.json').write_text(json.dumps({'checks': len(reports), 'failures': 0, 'results': reports}, indent=2), encoding='utf8')
    print(f'TIFF native pixels: {len(reports)} checks, 0 failures')


if __name__ == '__main__':
    main()
