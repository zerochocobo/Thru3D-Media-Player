"""Synthetic MKV attachments; production header-only reader, no personal media."""
import argparse
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/output/embedded-cover'

def run(*args):
    subprocess.run([str(x) for x in args], check=True, capture_output=True)

def prepare():
    OUT.mkdir(parents=True, exist_ok=True)
    for name, size, color in [('cover', '24x36', 'red'), ('cover_land', '64x36', 'blue')]:
        run('ffmpeg', '-v', 'error', '-y', '-f', 'lavfi', '-i', f'color=c={color}:s={size}', '-frames:v', '1', OUT / (name + '.png'))
    (OUT / 'font.ttf').write_bytes(b'This is not a cover image.')
    (OUT / 'oversize.png').write_bytes((OUT / 'cover.png').read_bytes() + bytes(8*1024*1024))
    cases = {'none': [], 'portrait': [('cover.png', 'cover.png')],
             'landscape': [('cover.png', 'cover.png'), ('cover_land.png', 'COVER_LAND.PNG')],
             'font': [('font.ttf', 'cover.png')], 'oversize': [('oversize.png', 'cover.png')]}
    for name, attachments in cases.items():
        args = ['ffmpeg', '-v', 'error', '-y', '-i', ROOT / 'build/output/original-capture/avc.mp4', '-map', '0:v:0', '-c', 'copy']
        for i, (file, title) in enumerate(attachments):
            args += ['-attach', OUT/file, f'-metadata:s:t:{i}', 'mimetype=image/png', f'-metadata:s:t:{i}', 'filename='+title]
        run(*args, OUT/(name+'.mkv'))

def verify():
    for name, expected in [('none', None), ('portrait', 'cover.png'), ('landscape', 'cover_land.png'), ('font', None), ('oversize', None)]:
        actual = (OUT/(name+'.bin')).read_bytes()
        assert actual == ((OUT/expected).read_bytes() if expected else b''), name
    print('Embedded cover native checks: passed (5; exact attachment bytes, priority, absent, invalid, size limit)')

if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('action', choices=['prepare', 'verify'])
    prepare() if parser.parse_args().action == 'prepare' else verify()
