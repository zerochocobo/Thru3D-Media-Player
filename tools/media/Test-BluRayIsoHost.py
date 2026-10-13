"""Decode real ISO video AND audio; an empty FFmpeg output never passes."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('iso')
parser.add_argument('--binary-dir', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--seek', type=float, default=3600)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
env = os.environ.copy()
env['LD_LIBRARY_PATH'] = ':'.join(str(args.binary_dir / lib) for lib in (
    'libavcodec', 'libavformat', 'libavfilter', 'libavdevice', 'libavutil', 'libswscale', 'libswresample'))
results = []
for label, position in [('start', 0), ('seek', args.seek)]:
    command = [str(args.binary_dir / 'ffmpeg'), '-nostdin', '-v', 'verbose',
               '-ss', str(position), '-f', 'bd_mvc', '-i', args.iso,
               '-map', '0:v:0', '-map', '0:a:0', '-t', '3', '-f', 'null', '-']
    run = subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, env=env, timeout=300)
    log = run.stderr.decode('utf-8', errors='replace')
    (args.output / f'{label}.log').write_text(log)
    frames = re.findall(r'Output stream #0:0 \(video\): (\d+) frames encoded', log)
    samples = re.findall(r'Output stream #0:1 \(audio\): \d+ frames encoded \((\d+) samples\)', log)
    video = int(frames[-1]) if frames else 0
    audio = int(samples[-1]) if samples else 0
    passed = run.returncode == 0 and video >= 50 and audio >= 96000 and not re.search(
        r'Error during demuxing|decode errors;|MVC invalid|MVC pair DTS mismatch|missing a matched', log.replace('0 decode errors;', ''))
    results.append(dict(case=label, position=position, video_frames=video, audio_samples=audio, passed=passed))
    print(json.dumps(results[-1]), flush=True)
(args.output / 'result.json').write_text(json.dumps(results, indent=2) + '\n')
raise SystemExit(0 if all(r['passed'] for r in results) else 1)
