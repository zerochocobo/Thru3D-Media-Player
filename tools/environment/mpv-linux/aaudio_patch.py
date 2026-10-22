"""Apply/verify the AAudio clock fix (0005) on top of the live-capture ao_aaudio.c."""
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[3]
DIRECTORY = ROOT/'native/mpv/patches'
MARKER = '.quest-aaudio-manifest.json'
APPLIED = '.quest-aaudio-applied.patch'


def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()


def matches(mpv, files):
    return all((mpv/name).exists() and sha(mpv/name) == digest for name, digest in files.items())


def unapply_aaudio_patch(mpv):
    """Restore the live-capture ao_aaudio.c so the earlier layers verify unchanged."""
    marker, applied = mpv/MARKER, mpv/APPLIED
    if not marker.exists():
        return
    previous = json.loads(marker.read_text())
    if not applied.exists() or sha(applied) != previous['patch_sha256'] or not matches(mpv, previous['patched_files_sha256']):
        raise ValueError('Modified AAudio clock build tree; refuse to overwrite')
    subprocess.run(['git', 'apply', '--reverse', '--check', str(applied)], cwd=mpv, check=True)
    subprocess.run(['git', 'apply', '--reverse', str(applied)], cwd=mpv, check=True)
    marker.unlink(); applied.unlink()


def apply_aaudio_patch(mpv):
    patch = DIRECTORY/'0005-mpv-aaudio-clock.patch'
    record = json.loads((DIRECTORY/'aaudio-clock-manifest.json').read_text())
    capture = json.loads((DIRECTORY/'live-capture-manifest.json').read_text())
    for name, digest in record['inputs_sha256'].items():
        if sha(ROOT/name) != digest: raise ValueError('Regenerate the AAudio clock patch: ' + name)
    if sha(patch) != record['patch_sha256'] or capture['patch_sha256'] != record['capture_patch_sha256']:
        raise ValueError('AAudio clock patch or its live-capture base changed')
    if not matches(mpv, record['base_files_sha256']):
        raise ValueError('AAudio clock base differs from the live-capture source')
    subprocess.run(['git', 'apply', '--check', str(patch)], cwd=mpv, check=True)
    subprocess.run(['git', 'apply', str(patch)], cwd=mpv, check=True)
    if not matches(mpv, record['patched_files_sha256']): raise ValueError('AAudio clock patched source differs')
    (mpv/MARKER).write_text(json.dumps(record, indent=2) + '\n')
    (mpv/APPLIED).write_bytes(patch.read_bytes())
