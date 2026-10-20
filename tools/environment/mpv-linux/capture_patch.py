"""Verify the playback-observer layer without invalidating an unchanged PGS base."""
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[3]
DIRECTORY = ROOT/'native/mpv/patches'
def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def matches(mpv, record):
    return all((mpv/name).exists() and sha(mpv/name)==digest for name,digest in record['patched_files_sha256'].items())

def prepare_base(mpv):
    """Return true only if the current PGS + observer layers already verify."""
    marker=mpv/'.quest-capture-manifest.json'; applied=mpv/'.quest-capture-applied.patch'
    if not marker.exists(): return False
    previous=json.loads(marker.read_text())
    if not applied.exists() or sha(applied)!=previous['patch_sha256'] or not matches(mpv,previous):
        raise ValueError('Modified live-capture build tree; refuse to overwrite')
    wanted=json.loads((DIRECTORY/'live-capture-manifest.json').read_text())
    pgs=json.loads((DIRECTORY/'pgs-bitmap-manifest.json').read_text())
    unchanged=previous==wanted and wanted['pgs_patch_sha256']==pgs['patch_sha256']
    for name,digest in pgs['patched_files_sha256'].items():
        if name in previous['base_files_sha256']:
            unchanged &= previous['base_files_sha256'][name]==digest
        else: unchanged &= (mpv/name).exists() and sha(mpv/name)==digest
    if unchanged: return True
    subprocess.run(['git','apply','--reverse','--check',str(applied)],cwd=mpv,check=True)
    subprocess.run(['git','apply','--reverse',str(applied)],cwd=mpv,check=True)
    marker.unlink(); applied.unlink()
    return False

def apply_capture_patch(mpv):
    patch=DIRECTORY/'0004-mpv-live-capture.patch'
    record=json.loads((DIRECTORY/'live-capture-manifest.json').read_text())
    for name,digest in record['inputs_sha256'].items():
        if sha(ROOT/name)!=digest: raise ValueError('Regenerate the playback observer for current source: '+name)
    pgs=json.loads((DIRECTORY/'pgs-bitmap-manifest.json').read_text())
    if sha(patch)!=record['patch_sha256'] or pgs['patch_sha256']!=record['pgs_patch_sha256']:
        raise ValueError('Observer patch or its PGS base changed')
    if not matches(mpv,record):
        for name,digest in record['base_files_sha256'].items():
            if sha(mpv/name)!=digest: raise ValueError('Observer base differs: '+name)
        subprocess.run(['git','apply','--check',str(patch)],cwd=mpv,check=True)
        subprocess.run(['git','apply',str(patch)],cwd=mpv,check=True)
    if not matches(mpv,record): raise ValueError('Observer patched source differs')
    (mpv/'.quest-capture-manifest.json').write_text(json.dumps(record,indent=2)+'\n')
    (mpv/'.quest-capture-applied.patch').write_bytes(patch.read_bytes())
