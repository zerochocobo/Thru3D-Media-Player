"""Verify real MVC clip joins, nonsequential seeks and optional whole-title decode.

Run in the Linux native-build environment. All decoded output stays in memory;
only technical JSON counters and diagnostics are saved under --output.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('iso')
    parser.add_argument('--binary-dir', type=Path, required=True)
    parser.add_argument('--ffmpeg-source', type=Path, required=True)
    parser.add_argument('--clip-boundaries', type=float, nargs='+', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--full', action='store_true', help='Also decode and verify the entire title')
    parser.add_argument('--full-workers', type=int, choices=(1, 2, 4), default=1,
                        help='Parallel overlapping whole-clip runs; 1 keeps one continuous title instance')
    args = parser.parse_args()
    if args.full_workers != 1 and not args.full:
        parser.error('--full-workers requires --full')
    args.output.mkdir(parents=True, exist_ok=True)
    binary = args.binary_dir.resolve()
    root = Path(__file__).resolve().parents[2]
    source = root / 'benchmarks/native_mvc/iso_multiclip_probe.c'
    probe = args.output.resolve() / 'iso_multiclip_probe'
    boundaries = args.clip_boundaries
    if boundaries != sorted(set(boundaries)) or boundaries[0] < 3:
        parser.error('Clip boundaries must be unique, increasing and at least three seconds from the start')
    env = os.environ.copy()
    env['LD_LIBRARY_PATH'] = ':'.join(str(binary / lib) for lib in (
        'libavcodec', 'libavformat', 'libavfilter', 'libavdevice', 'libavutil', 'libswscale', 'libswresample'))
    inputs = [source, Path(__file__).resolve(), root / 'native/mpv/mvc/ffmpeg_bd_mvc.c',
              root / 'native/mpv/mvc/ffmpeg_h264_mvc.c', binary / 'ffprobe']
    inputs += [binary / lib / (lib + '.so') for lib in ('libavformat', 'libavcodec', 'libavutil')]

    def hashes():
        return {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}

    input_hashes = hashes()
    compile_command = ['cc', '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror',
                       '-I' + str(args.ffmpeg_source.resolve()), '-I' + str(binary), str(source)]
    compile_command += ['-L' + str(binary / lib) for lib in ('libavformat', 'libavcodec', 'libavutil')]
    compile_command += ['-lavformat', '-lavcodec', '-lavutil', '-lm', '-o', str(probe)]
    subprocess.run(compile_command, env=env, check=True)
    probe_hash = hashlib.sha256(probe.read_bytes()).hexdigest()
    run = subprocess.run([str(binary / 'ffprobe'), '-v', 'warning', '-f', 'bd_mvc',
                          '-show_entries', 'format=duration:format_tags=thru3d_clip_count', '-of', 'json', args.iso],
                         env=env, capture_output=True, timeout=300)
    (args.output / 'metadata.json').write_bytes(run.stdout)
    (args.output / 'metadata.log').write_bytes(run.stderr)
    run.check_returncode()
    metadata = json.loads(run.stdout)['format']
    duration = float(metadata['duration'])
    count = int(metadata['tags']['thru3d_clip_count'])
    if count != len(boundaries) + 1 or boundaries[-1] + 12 >= duration:
        raise ValueError('Boundary count/range does not match the real title metadata')
    # Cross every join continuously, then jump backwards/forwards and revisit
    # the same positions with the same still-live demuxer and decoder instances.
    targets = [0] + [b - 3 for b in boundaries]
    targets += [boundaries[-1] + 5, boundaries[0] + 5, boundaries[len(boundaries)//2] + 5]
    targets += [boundaries[-1] + 5, boundaries[0] + 5, 0]

    def execute(label, window, positions, timeout):
        with (args.output / f'{label}.jsonl').open('w') as out, (args.output / f'{label}.log').open('w') as err:
            result = subprocess.run([str(probe), args.iso, window, *[f'{p:.9f}' for p in positions]],
                                    stdout=out, stderr=err, env=env, timeout=timeout)
        rows = [json.loads(line) for line in (args.output / f'{label}.jsonl').read_text().splitlines() if line.strip()]
        result.check_returncode()
        if len(rows) != len(positions) or not all(row['passed'] for row in rows):
            raise ValueError(f'{label} did not verify every requested interval')
        return rows

    rows = execute('windows', '6', targets, 900)
    previous = {}
    for row in rows:
        key = row['target']
        signature = (row['video_pairs'], row['first_pts'], row['last_pts'], row['eye_hashes'])
        if key in previous and previous[key] != signature:
            raise ValueError('Revisited seek target produced different stereo frames')
        previous[key] = signature
    tail = execute('tail', 'all', [max(0, duration - 6)], 300)
    full = []
    if args.full and args.full_workers == 1:
        full = execute('continuous', 'all', [0], 7200)
    elif args.full:
        # Overlap each boundary by six seconds. Every clip is decoded in full
        # with its following transition, and the last run drains the real EOF.
        points = [0] + boundaries + [duration]

        def whole_clip(index):
            start = max(0, points[index] - 3)
            finish = min(duration, points[index + 1] + 3)
            window = 'all' if index == count - 1 else f'{finish-start:.9f}'
            return execute(f'continuous-{index}', window, [start], 7200)[0]

        with ThreadPoolExecutor(max_workers=args.full_workers) as pool:
            full = list(pool.map(whole_clip, range(count)))
    clip_mask = 0
    for row in full:
        clip_mask |= row['clip_mask']
    if full and clip_mask != (1 << count) - 1:
        raise ValueError('Whole-title decode did not traverse every clip')
    if hashes() != input_hashes or hashlib.sha256(probe.read_bytes()).hexdigest() != probe_hash:
        raise ValueError('Validation inputs changed during the run')
    result = {'passed': True, 'clip_count': count, 'duration_seconds': duration,
              'join_windows': len(boundaries), 'seek_windows': len(rows),
              'revisited_targets': len(rows) - len(previous), 'windows': rows, 'continuous': full,
              'tail': tail,
              'coverage': 'whole title' if args.full else 'sampled joins, nonsequential/repeated seeks and final EOF',
              'full_workers': args.full_workers,
              'continuous_strategy': ('single title instance' if args.full_workers == 1 else
                                      'overlapping continuous whole-clip runs covering the entire title and every join'),
              'probe_source_sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
              'inputs_sha256': input_hashes, 'probe_binary_sha256': probe_hash,
              'scope': 'Native demux/decode, bit-exact independent AVC base-eye pixels, paired MVC views and audio timestamps; no APK, display, physical audio or sustained headset performance.'}
    (args.output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({key: result[key] for key in ('passed', 'clip_count', 'join_windows', 'seek_windows', 'revisited_targets')}), flush=True)


if __name__ == '__main__':
    main()
