"""Check production MPV color orientation against independent FFmpeg decoding.

Uses a native executable (no APK installation or player restart).
Build native_mpv_rotation with Android CMake. The probe directory must contain
rotation_probe, frame_geometry_test and libc++_shared.so.
All generated fixtures and reports live under build/output/.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
LIBS = ROOT / 'android/player-plugin/src/main/jniLibs/arm64-v8a'
REMOTE = '/data/local/tmp/thru3d-rotation-fix-20261012'


def run(*args):
    result = subprocess.run([str(a) for a in args], capture_output=True, timeout=90)
    if result.returncode:
        raise RuntimeError(f'Command failed ({result.returncode}): {args}\n' +
            result.stdout.decode('utf-8', errors='replace') + result.stderr.decode('utf-8', errors='replace'))
    return result.stdout


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--adb', default='adb')
    parser.add_argument('--ffmpeg', default='ffmpeg')
    parser.add_argument('--probe', type=Path, default=ROOT / 'build/rotation-native-probe')
    parser.add_argument('--out', type=Path, default=ROOT / 'build/output/rotation-fix-20261012')
    parser.add_argument('--serial', default='2G0YC5ZF7V0664')
    parser.add_argument('--hardware', action='store_true', help='Require actual MediaCodec; rejects software fallback (needs an Android VM)')
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)

    def adb(*parts):
        return run(args.adb, '-s', args.serial, *parts)

    adb('shell', 'mkdir', '-p', REMOTE)
    for lib in LIBS.glob('*.so'):
        if lib.name.startswith(('libmpv', 'libav', 'libsw')):
            adb('push', lib, REMOTE + '/' + lib.name)
    for name in ['rotation_probe', 'frame_geometry_test', 'libc++_shared.so']:
        adb('push', args.probe / name, REMOTE + '/' + name)
    adb('shell', 'chmod', '755', REMOTE + '/rotation_probe', REMOTE + '/frame_geometry_test')
    print(adb('shell', f'LD_LIBRARY_PATH={REMOTE} {REMOTE}/frame_geometry_test').decode().strip(), flush=True)
    base = args.out / 'corners_0.mp4'
    run(args.ffmpeg, '-v', 'error', '-y', '-f', 'lavfi', '-i',
        'color=black:s=128x72:r=30:d=4,drawbox=x=0:y=0:w=64:h=36:color=red:t=fill,'
        'drawbox=x=64:y=0:w=64:h=36:color=green:t=fill,'
        'drawbox=x=0:y=36:w=64:h=36:color=blue:t=fill,'
        'drawbox=x=64:y=36:w=64:h=36:color=yellow:t=fill',
        '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-g', '30', '-crf', '12', base)
    fixtures = [base]
    for degrees in [90, 180, 270]:
        file = args.out / f'corners_{degrees}.mp4'
        # ffprobe's matrix convention differs from MPV's clockwise convention.
        run(args.ffmpeg, '-v', 'error', '-y', '-display_rotation:v:0', str(-degrees),
            '-i', base, '-c', 'copy', file)
        fixtures.append(file)
    real = ROOT / 'build/output/rotation-investigation-20261012/rotated.mp4'
    if real.exists():
        fixtures.append(real)
    observations = []
    for file in fixtures:
        adb('push', file, REMOTE + '/fixture.mp4')
        for hardware in ([False, True] if args.hardware else [False]):
            label = file.stem + ('_hw' if hardware else '_sw')
            cap = 0
            direct = file != base
            command = (f'LD_LIBRARY_PATH={REMOTE} {REMOTE}/rotation_probe {REMOTE}/fixture.mp4 {REMOTE}/{label} '
                f'{str(hardware).lower()} {cap} {str(direct).lower()}')
            raw = adb('shell', command).decode('utf-8', errors='replace')
            (args.out / (label + '-stdout.txt')).write_text(raw, encoding='utf-8')
            report = json.loads(next(line for line in raw.splitlines() if line.startswith('{')))
            (args.out / (label + '.json')).write_text(json.dumps(report, indent=2), encoding='utf-8')
            if report.get('state') != 'passed' or not report.get('disposed'):
                raise AssertionError(f'{label}: {report}')
            native = report['native_status']
            actual_hw = native['details']['hwdec_current']
            assert actual_hw == ('mediacodec' if hardware else 'no'), (label, actual_hw)
            rotation = report['open']['source_rotation_degrees']
            assert report['redraw']['frame_id'] == report['open']['frame_id']
            assert report['redraw']['pts_us'] == report['open']['pts_us']
            assert report['seek']['source_epoch'] > report['open']['source_epoch']
            assert abs(report['seek']['pts_us'] - 1500000) <= 17000
            assert report['resume']['pts_us'] > report['seek']['pts_us']
            for phase in ['open', 'redraw', 'seek', 'resume']:
                frame = report[phase]
                assert frame['rotation_degrees'] == 0 and frame['source_rotation_degrees'] == rotation
                assert frame['color_target'] == 'GL_TEXTURE_2D' and 'hardware_buffer' not in frame
                w, h = frame['width'], frame['height']
                expected_shape = (72, 128) if rotation in (90, 270) else (128, 72)
                if file == real:
                    expected_shape = (2160, 3840)
                assert (w, h) == expected_shape, (label, phase, w, h, rotation)
                actual_file = args.out / (label + '_' + phase + '.rgba')
                adb('pull', REMOTE + '/' + actual_file.name, actual_file)
                actual = np.frombuffer(actual_file.read_bytes(), np.uint8).reshape(h, w, 4)
                reference = run(args.ffmpeg, '-v', 'error', '-ss', f'{frame["pts_us"] / 1e6:.6f}', '-i', file,
                    '-vf', f'scale={w}:{h}:flags=bilinear', '-frames:v', '1', '-pix_fmt', 'rgba', '-f', 'rawvideo', '-')
                expected = np.frombuffer(reference, np.uint8).reshape(h, w, 4)
                difference = np.abs(actual[..., :3].astype(np.int16) - expected[..., :3].astype(np.int16))
                metrics = {'mean_bytes': float(difference.mean()), 'p99_bytes': float(np.percentile(difference, 99))}
                if file != real:
                    # Existing GPU-dumb YUV interpolation differs from swscale along abrupt
                    # chroma edges. Check the four quadrant interiors independently of those
                    # edges, while retaining the whole-frame mean to catch geometric distortion.
                    mask = np.ones((h, w), dtype=bool)
                    mask[h // 2 - 4:h // 2 + 4, :] = False
                    mask[:, w // 2 - 4:w // 2 + 4] = False
                    metrics['interior_max_bytes'] = int(difference[mask].max())
                    assert metrics['mean_bytes'] < 3 and metrics['interior_max_bytes'] <= 3, (label, phase, metrics)
                else:
                    assert metrics['mean_bytes'] < 3 and metrics['p99_bytes'] < 25, (label, phase, metrics)
                assert np.all(actual[..., 3] == 255)
                observations.append({'case': label, 'phase': phase, 'rotation': rotation, 'size': [w, h],
                    'pts_us': frame['pts_us'], 'epoch': frame['source_epoch'], **metrics})
            print(json.dumps({'case': label, 'state': 'passed', 'rotation': rotation, 'hwdec': actual_hw}), flush=True)
    fingerprint = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
        for p in [ROOT / 'native/mpv/mpv_source.cpp', ROOT / 'native/mpv/frame_geometry.h']}
    (args.out / 'verified.json').write_text(json.dumps({'state': 'passed', 'source_sha256': fingerprint,
        'scope': 'Production native source, EGL and FFmpeg software decoding on device; color orientation, paused redraw, exact seek, resume and disposal. No APK, Java VM, MediaCodec, Godot/RVM inference or Surface swapchain.',
        'observations': observations}, indent=2), encoding='utf-8')


if __name__ == '__main__':
    main()
