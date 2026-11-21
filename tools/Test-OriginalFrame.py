"""Independent pixel/PTS oracle for the production full-size screenshot fallback.

Run prepare on Windows, tools/Test-OriginalFrameHost.sh and execute in WSL,
then verify on Windows. All fixtures and outputs are disposable, synthetic media.
"""
import argparse
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/output/screenshot-20261024/host'
CASES = [('avc-before', 'avc', 1015000, 30), ('avc-after', 'avc', 1023000, 31),
         ('offset', 'offset', 1023000, 31), ('hevc10', 'hevc10', 1023000, 31),
         ('first', 'avc', 0, 0), ('last', 'avc', 1980000, 59)]
VIDEO_FIXTURES = [('video.mov', 'copy', 'mov'), ('video.m4v', 'copy', 'mp4'),
                  ('stereo.mk3d', 'copy', 'matroska'), ('video.webm', 'libvpx-vp9', 'webm'),
                  ('video.ts', 'copy', 'mpegts'), ('video.m2ts', 'copy', 'mpegts'),
                  ('video.mpg', 'mpeg2video', 'mpeg'), ('video.vob', 'mpeg2video', 'vob'),
                  ('video.avi', 'mpeg4', 'avi'), ('video.wmv', 'wmv2', 'asf'), ('video.flv', 'flv', 'flv')]


def run(args):
    return subprocess.run([str(x) for x in args], capture_output=True, check=True)


def prepare():
    OUT.mkdir(parents=True, exist_ok=True)
    for name, codec, pix, extra in [('avc', 'libx264', 'yuv420p', []),
                                  ('hevc10', 'libx265', 'yuv420p10le', ['-x265-params', 'pools=2:frame-threads=2'])]:
        run(['ffmpeg', '-y', '-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=640x320:rate=30',
             '-t', '2', '-an', '-c:v', codec, '-threads', '2', '-pix_fmt', pix, '-g', '60', '-bf', '3',
             '-colorspace', 'bt709', '-color_range', 'tv', *extra, OUT / (name + '.mp4')])
    run(['ffmpeg', '-y', '-v', 'error', '-i', OUT / 'avc.mp4', '-c', 'copy', '-output_ts_offset', '5', OUT / 'offset.mp4'])
    run(['ffmpeg', '-y', '-v', 'error', '-i', OUT / 'avc.mp4', '-c', 'copy', OUT / 'no-cover-avc.mkv'])
    run(['ffmpeg', '-y', '-v', 'error', '-i', OUT / 'hevc10.mp4', '-c', 'copy', OUT / 'no-cover-hevc.mkv'])
    run(['ffmpeg', '-y', '-v', 'error', '-i', OUT / 'avc.mp4', '-vf', 'scale=320:160',
         '-frames:v', '1', OUT / 'cover.jpg'])
    run(['ffmpeg', '-y', '-v', 'error', '-i', OUT / 'avc.mp4', '-c', 'copy', '-attach', OUT / 'cover.jpg',
         '-metadata:s:t', 'mimetype=image/jpeg', '-metadata:s:t', 'filename=cover.jpg', OUT / 'embedded-cover.mkv'])
    for filename, codec, container in VIDEO_FIXTURES:
        m2ts = ['-mpegts_m2ts_mode', '1'] if filename.endswith('.m2ts') else []
        run(['ffmpeg', '-y', '-v', 'error', '-i', OUT / 'avc.mp4', '-an', '-c:v', codec,
             '-threads', '2', '-f', container, *m2ts, OUT / filename])
    run(['ffmpeg', '-y', '-v', 'error', '-f', 'lavfi', '-i', 'color=0x608ed3:size=7680x3840:rate=1',
         '-frames:v', '1', '-c:v', 'libx265', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p10le',
         '-x265-params', 'pools=2:frame-threads=1', OUT / 'video-8k.mkv'])
    (OUT / 'invalid.mp4').write_bytes(b'not a video')
    for name, fixture, _, frame in CASES:
        run(['ffmpeg', '-y', '-v', 'error', '-i', OUT / (fixture + '.mp4'),
             '-vf', f'select=eq(n\\,{frame}),scale=iw:ih:flags=bilinear:in_color_matrix=bt709:in_range=tv:out_range=pc,format=rgba',
             '-frames:v', '1', '-pix_fmt', 'rgba', '-f', 'rawvideo', OUT / (name + '.expected.rgba')])
    print('Prepared B-frame AVC, nonzero timeline origin, 10-bit HEVC and independent RGBA references')


def execute():
    reports = []
    for name, fixture, position, frame in CASES:
        result = json.loads(run([OUT / 'frame-host', OUT / (fixture + '.mp4'), position, OUT / (name + '.rgba')]).stdout)
        result.update(name=name, requested_us=position, expected_frame=frame)
        reports.append(result)
    for name, fixture, position, extra in [('cancelled', 'avc', 1000000, ['cancel']),
                                         ('invalid', 'invalid', 1000000, []), ('past-eof', 'avc', 4000000, [])]:
        target = OUT / (name + '.rgba')
        target.unlink(missing_ok=True)
        result = subprocess.run([str(OUT / 'frame-host'), str(OUT / (fixture + '.mp4')), str(position), str(target), *extra], capture_output=True)
        assert result.returncode != 0 and not target.exists(), name
        reports.append({'name': name, 'rejected': True})
    for fixture, budget, extra, decoded in [
        ('no-cover-avc.mkv', 4 * 1024**2, [], True),
        ('no-cover-hevc.mkv', 4 * 1024**2, [], True),
        ('avc.mp4', 4 * 1024**2, [], True),
        ('video-8k.mkv', 4 * 1024**2, [], True),
        *[(fixture, 4 * 1024**2, [], True) for fixture, _, _ in VIDEO_FIXTURES],
        ('no-cover-avc.mkv', 1024, [], False),
        ('no-cover-avc.mkv', 4 * 1024**2, ['cancel'], False),
        ('invalid.mp4', 4 * 1024**2, [], False),
    ]:
        result = json.loads(run([OUT / 'frame-host', OUT / fixture, 'thumbnail', budget, *extra]).stdout)
        assert result['decoded'] == decoded and result['bytes'] <= budget, (fixture, budget, extra, result)
        if extra:
            assert result['bytes'] == 0, result
        print(f'Thumbnail {fixture}, limit {budget}, {extra}: {result}')
    for fixture in ['video.ts', 'video.m2ts', 'no-cover-avc.mkv']:
        result = json.loads(run([OUT / 'frame-host', OUT / fixture, 'prefix', 4 * 1024**2]).stdout)
        assert result['decoded'] and result['bytes'] <= 4 * 1024**2, (fixture, result)
        print(f'Non-seekable thumbnail {fixture}: {result}')
    embedded = json.loads(run([OUT / 'frame-host', OUT / 'embedded-cover.mkv', 'thumbnail', 4 * 1024**2]).stdout)
    assert not embedded['decoded'] and embedded['cover_bytes'] == (OUT / 'cover.jpg').stat().st_size, embedded
    print(f'Embedded image selected without video decoding: {embedded}')
    (OUT / 'reports.json').write_text(json.dumps(reports, indent=2))
    print('Decoded six full-size stills; rejected cancellation, invalid input and out-of-range time')


def verify():
    import numpy as np
    reports = json.loads((OUT / 'reports.json').read_text())
    for result in reports:
        if result.get('rejected'): continue
        assert (result['width'], result['height']) == (640, 320), result
        assert abs(result['pts_us'] - round(result['expected_frame'] * 1000000 / 30)) <= 1, result
        actual = np.fromfile(OUT / (result['name'] + '.rgba'), dtype=np.uint8).astype(np.int16)
        expected = np.fromfile(OUT / (result['name'] + '.expected.rgba'), dtype=np.uint8).astype(np.int16)
        assert actual.shape == expected.shape == (640 * 320 * 4,), result
        difference = np.abs(actual - expected)
        result.update(max_pixel_error=int(difference.max()), mean_pixel_error=float(difference.mean()))
        assert difference.max() <= 3, result
    (OUT / 'verification.json').write_text(json.dumps({'state': 'passed', 'cases': reports}, indent=2))
    print(json.dumps({'state': 'passed', 'cases': reports}, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('phase', choices=('prepare', 'execute', 'verify'))
    args = parser.parse_args()
    globals()[args.phase]()
