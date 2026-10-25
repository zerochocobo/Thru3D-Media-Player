#!/usr/bin/env python3
"""Synthetic decode/YUV/mux regression; Android hardware encoding still requires device validation."""
import argparse
import json
import os
from pathlib import Path
import shlex
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/output/pip-clip'


def run(args):
    return subprocess.run([str(x) for x in args], check=True, capture_output=True)


def ffmpeg(*args):
    return run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', *args])


def probe(path, *args):
    return json.loads(run(['ffprobe', '-v', 'error', *args, '-of', 'json', path]).stdout)


def linux(path):
    path = str(Path(path).resolve()).replace('\\', '/')
    return '/mnt/' + path[0].lower() + path[2:] if os.name == 'nt' else path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--host', type=Path, default=OUT / 'pip-clip-host')
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    source, encoded, result = [OUT / name for name in ('source.mkv', 'encoded.mp4', 'composed.mkv')]
    raw, times = OUT / 'decoded.rgba', OUT / 'timestamps.txt'
    ffmpeg('-f', 'lavfi', '-i', 'testsrc2=size=320x160:rate=60:duration=2', '-f', 'lavfi', '-i',
           'sine=frequency=997:sample_rate=48000:duration=2', '-c:v', 'libx264', '-bf', '3',
           '-color_primaries', 'bt709', '-color_trc', 'bt709', '-colorspace', 'bt709',
           '-c:a', 'pcm_f32le', '-ac', '2', '-output_ts_offset', '2', source)
    # Independent host-only stand-in for Android MediaCodec. Production never invokes a CLI encoder.
    ffmpeg('-i', source, '-an', '-vf', r'select=not(mod(n\,2))', '-fps_mode', 'vfr', '-c:v', 'libx264', '-bf', '0', encoded)
    commands = [[args.host, 'decode', source, raw, times], [args.host, 'mux', encoded, source, result]]
    if os.name == 'nt':
        commands = [[linux(c) if isinstance(c, Path) else c for c in command] for command in commands]
        report = run(['wsl.exe', '-e', 'bash', '-c', ' && '.join(shlex.join(c) for c in commands)]).stdout.decode()
    else:
        report = ''.join(run(command).stdout.decode() for command in commands)
    (OUT / 'host.log').write_text(report, encoding='utf-8')
    pts = [int(line) for line in times.read_text().splitlines()]
    assert len(pts) == 60, len(pts)
    assert all(abs(value - index * 1e6 / 30) < 1001 for index, value in enumerate(pts)), pts
    assert raw.stat().st_size == 60 * 320 * 160 * 4
    metadata = probe(result, '-show_streams', '-show_format')
    tags = {key.lower(): value for key, value in metadata['format']['tags'].items()}
    assert json.loads(tags['thru3d_mode'])['stereo_sbs']
    assert tags['thru3d_pip'] == 'composed'
    streams = {s['codec_type']: s for s in metadata['streams']}
    assert streams['video']['codec_name'] == 'h264'
    assert streams['audio']['codec_name'] == 'pcm_f32le'
    assert abs(float(streams['audio']['start_time'])) < .002
    assert abs(float(streams['video']['start_time'])) < .002
    first = ffmpeg('-i', source, '-map', '0:a', '-f', 'f32le', '-').stdout
    second = ffmpeg('-i', result, '-map', '0:a', '-f', 'f32le', '-').stdout
    assert first == second and len(first) == 48000 * 2 * 2 * 4
    evidence = {'frames': len(pts), 'audio_bytes_identical': len(first), 'source_origin_seconds': 2,
                'max_frame_timestamp_error_us': max(abs(p - i * 1e6 / 30) for i, p in enumerate(pts)),
                'strided_yuv_and_bounds': 'passed', 'metadata': tags, 'android_encoder_tested': False}
    (OUT / 'host-evidence.json').write_text(json.dumps(evidence, indent=2), encoding='utf-8')
    print(report.strip())
    print('PiP clip host decode, 30 fps timestamps, unchanged PCM and metadata passed')


if __name__ == '__main__':
    main()
