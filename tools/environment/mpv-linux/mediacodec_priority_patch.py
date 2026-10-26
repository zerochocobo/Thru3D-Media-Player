"""Apply/verify the MediaCodec priority patch (0007) on the Dolby-patched mediacodecdec.c."""
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[3]
DIRECTORY = ROOT/'native/mpv/patches'
MARKER = '.quest-priority-manifest.json'
APPLIED = '.quest-priority-applied.patch'


def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()


def matches(ffmpeg, files):
    return all((ffmpeg/name).exists() and sha(ffmpeg/name) == digest for name, digest in files.items())


def unapply_priority_patch(ffmpeg):
    """Restore the Dolby-patched mediacodecdec.c so 0002 verifies unchanged."""
    marker, applied = ffmpeg/MARKER, ffmpeg/APPLIED
    if not marker.exists():
        return
    previous = json.loads(marker.read_text())
    if not applied.exists() or sha(applied) != previous['patch_sha256'] or not matches(ffmpeg, previous['patched_files_sha256']):
        raise ValueError('Modified MediaCodec priority build tree; refuse to overwrite')
    subprocess.run(['git', 'apply', '--reverse', '--check', str(applied)], cwd=ffmpeg, check=True)
    subprocess.run(['git', 'apply', '--reverse', str(applied)], cwd=ffmpeg, check=True)
    marker.unlink(); applied.unlink()


def apply_priority_patch(ffmpeg):
    patch = DIRECTORY/'0007-ffmpeg-mediacodec-priority.patch'
    record = json.loads((DIRECTORY/'mediacodec-priority-manifest.json').read_text())
    for name, digest in record['inputs_sha256'].items():
        if sha(ROOT/name) != digest: raise ValueError('Regenerate the MediaCodec priority patch: ' + name)
    dovi = json.loads((DIRECTORY/'dovi-rpu-manifest.json').read_text())
    if sha(patch) != record['patch_sha256'] or dovi['patch_sha256'] != record['dovi_patch_sha256']:
        raise ValueError('MediaCodec priority patch or its Dolby base changed')
    if not matches(ffmpeg, record['base_files_sha256']):
        raise ValueError('MediaCodec priority base differs from the Dolby-patched source')
    subprocess.run(['git', 'apply', '--check', str(patch)], cwd=ffmpeg, check=True)
    subprocess.run(['git', 'apply', str(patch)], cwd=ffmpeg, check=True)
    if not matches(ffmpeg, record['patched_files_sha256']): raise ValueError('MediaCodec priority patched source differs')
    (ffmpeg/MARKER).write_text(json.dumps(record, indent=2) + '\n')
    (ffmpeg/APPLIED).write_bytes(patch.read_bytes())
