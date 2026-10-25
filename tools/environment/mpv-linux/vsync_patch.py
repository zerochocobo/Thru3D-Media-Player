"""Apply/verify the layer cadence patch (0006) on the pinned vo_mediacodec_embed.c."""
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[3]
DIRECTORY = ROOT/'native/mpv/patches'
MARKER = '.quest-cadence-manifest.json'
APPLIED = '.quest-cadence-applied.patch'


def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()


def matches(mpv, files):
    return all((mpv/name).exists() and sha(mpv/name) == digest for name, digest in files.items())


def unapply_vsync_patch(mpv):
    """Restore the pinned vo_mediacodec_embed.c before verifying or reapplying."""
    marker, applied = mpv/MARKER, mpv/APPLIED
    if not marker.exists():
        return
    previous = json.loads(marker.read_text())
    if not applied.exists() or sha(applied) != previous['patch_sha256'] or not matches(mpv, previous['patched_files_sha256']):
        raise ValueError('Modified layer cadence build tree; refuse to overwrite')
    subprocess.run(['git', 'apply', '--reverse', '--check', str(applied)], cwd=mpv, check=True)
    subprocess.run(['git', 'apply', '--reverse', str(applied)], cwd=mpv, check=True)
    marker.unlink(); applied.unlink()


def apply_vsync_patch(mpv):
    patch = DIRECTORY/'0006-mpv-layer-cadence.patch'
    record = json.loads((DIRECTORY/'layer-cadence-manifest.json').read_text())
    for name, digest in record['inputs_sha256'].items():
        if sha(ROOT/name) != digest: raise ValueError('Regenerate the layer cadence patch: ' + name)
    if sha(patch) != record['patch_sha256']:
        raise ValueError('Layer cadence patch changed')
    if not matches(mpv, record['base_files_sha256']):
        raise ValueError('Layer cadence base differs from the pinned source')
    subprocess.run(['git', 'apply', '--check', str(patch)], cwd=mpv, check=True)
    subprocess.run(['git', 'apply', str(patch)], cwd=mpv, check=True)
    if not matches(mpv, record['patched_files_sha256']): raise ValueError('Layer cadence patched source differs')
    (mpv/MARKER).write_text(json.dumps(record, indent=2) + '\n')
    (mpv/APPLIED).write_bytes(patch.read_bytes())
