"""Apply/verify the MediaCodec non-reference skip patch (0010) on the stall-patched mediacodecdec.c."""
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[3]
DIRECTORY = ROOT/'native/mpv/patches'
MARKER = '.quest-skip-manifest.json'
APPLIED = '.quest-skip-applied.patch'


def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()


def matches(ffmpeg, files):
    return all((ffmpeg/name).exists() and sha(ffmpeg/name) == digest for name, digest in files.items())


def unapply_skip_patch(ffmpeg):
    """Restore the stall-patched mediacodecdec.c so 0009, 0007 and 0002 verify unchanged."""
    marker, applied = ffmpeg/MARKER, ffmpeg/APPLIED
    if not marker.exists():
        return
    previous = json.loads(marker.read_text())
    if not applied.exists() or sha(applied) != previous['patch_sha256'] or not matches(ffmpeg, previous['patched_files_sha256']):
        raise ValueError('Modified MediaCodec skip build tree; refuse to overwrite')
    subprocess.run(['git', 'apply', '--reverse', '--check', str(applied)], cwd=ffmpeg, check=True)
    subprocess.run(['git', 'apply', '--reverse', str(applied)], cwd=ffmpeg, check=True)
    marker.unlink(); applied.unlink()


def apply_skip_patch(ffmpeg):
    patch = DIRECTORY/'0010-ffmpeg-mediacodec-skip-nonref.patch'
    record = json.loads((DIRECTORY/'mediacodec-skip-manifest.json').read_text())
    for name, digest in record['inputs_sha256'].items():
        if sha(ROOT/name) != digest: raise ValueError('Regenerate the MediaCodec skip patch: ' + name)
    stall = json.loads((DIRECTORY/'mediacodec-stall-manifest.json').read_text())
    if sha(patch) != record['patch_sha256'] or stall['patch_sha256'] != record['stall_patch_sha256']:
        raise ValueError('MediaCodec skip patch or its stall base changed')
    if not matches(ffmpeg, record['base_files_sha256']):
        raise ValueError('MediaCodec skip base differs from the stall-patched source')
    subprocess.run(['git', 'apply', '--check', str(patch)], cwd=ffmpeg, check=True)
    subprocess.run(['git', 'apply', str(patch)], cwd=ffmpeg, check=True)
    if not matches(ffmpeg, record['patched_files_sha256']): raise ValueError('MediaCodec skip patched source differs')
    (ffmpeg/MARKER).write_text(json.dumps(record, indent=2) + '\n')
    (ffmpeg/APPLIED).write_bytes(patch.read_bytes())
