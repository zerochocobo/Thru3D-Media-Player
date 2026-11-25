"""Apply/verify the MediaCodec feed stall patch (0009) on the priority-patched mediacodecdec.c."""
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[3]
DIRECTORY = ROOT/'native/mpv/patches'
MARKER = '.quest-stall-manifest.json'
APPLIED = '.quest-stall-applied.patch'


def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()


def matches(ffmpeg, files):
    return all((ffmpeg/name).exists() and sha(ffmpeg/name) == digest for name, digest in files.items())


def unapply_stall_patch(ffmpeg):
    """Restore the priority-patched mediacodecdec.c so 0007 (and then 0002) verify unchanged."""
    marker, applied = ffmpeg/MARKER, ffmpeg/APPLIED
    if not marker.exists():
        return
    previous = json.loads(marker.read_text())
    if not applied.exists() or sha(applied) != previous['patch_sha256'] or not matches(ffmpeg, previous['patched_files_sha256']):
        raise ValueError('Modified MediaCodec stall build tree; refuse to overwrite')
    subprocess.run(['git', 'apply', '--reverse', '--check', str(applied)], cwd=ffmpeg, check=True)
    subprocess.run(['git', 'apply', '--reverse', str(applied)], cwd=ffmpeg, check=True)
    marker.unlink(); applied.unlink()


def apply_stall_patch(ffmpeg):
    patch = DIRECTORY/'0009-ffmpeg-mediacodec-stall.patch'
    record = json.loads((DIRECTORY/'mediacodec-stall-manifest.json').read_text())
    for name, digest in record['inputs_sha256'].items():
        if sha(ROOT/name) != digest: raise ValueError('Regenerate the MediaCodec stall patch: ' + name)
    priority = json.loads((DIRECTORY/'mediacodec-priority-manifest.json').read_text())
    if sha(patch) != record['patch_sha256'] or priority['patch_sha256'] != record['priority_patch_sha256']:
        raise ValueError('MediaCodec stall patch or its priority base changed')
    if not matches(ffmpeg, record['base_files_sha256']):
        raise ValueError('MediaCodec stall base differs from the priority-patched source')
    subprocess.run(['git', 'apply', '--check', str(patch)], cwd=ffmpeg, check=True)
    subprocess.run(['git', 'apply', str(patch)], cwd=ffmpeg, check=True)
    if not matches(ffmpeg, record['patched_files_sha256']): raise ValueError('MediaCodec stall patched source differs')
    (ffmpeg/MARKER).write_text(json.dumps(record, indent=2) + '\n')
    (ffmpeg/APPLIED).write_bytes(patch.read_bytes())
