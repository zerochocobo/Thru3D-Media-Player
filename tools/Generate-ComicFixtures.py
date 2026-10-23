"""Rebuild synthetic comic archive fixtures; no personal media or app packaging."""
import argparse
from pathlib import Path
import struct
import subprocess
import zlib

p = argparse.ArgumentParser()
p.add_argument('--output', default='build/output/comic-archives/fixtures')
p.add_argument('--sevenzip', default=r'C:\Program Files\7-Zip\7z.exe')
p.add_argument('--rar', default=r'C:\Program Files\WinRAR\Rar.exe')
a = p.parse_args()
root = Path(a.output).resolve()
source = root / 'pages'
source.mkdir(parents=True, exist_ok=True)
def chunk(kind, data):
    return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data)&0xffffffff)
for number in [1,2,10]:
    data=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>2I5B',32,32,8,2,0,0,0))+chunk(b'IDAT',zlib.compress((b'\0'+bytes([number*10,70,150])*32)*32))+chunk(b'IEND',b'')
    (source/f'{number}.png').write_bytes(data)
def seven(name, args):
    out=root/name
    if out.exists(): out.unlink()
    subprocess.run([a.sevenzip,'a','-y','-bd',str(out),*args,'*.png'],cwd=source,check=True,stdout=subprocess.DEVNULL)
seven('plain.zip',['-tzip','-mm=Deflate'])
seven('store.cbz',['-tzip','-mm=Copy'])
seven('zipcrypto.zip',['-tzip','-pcomic-test','-mem=ZipCrypto'])
seven('aes.zip',['-tzip','-pcomic-test','-mem=AES256'])
seven('plain.7z',['-t7z','-ms=off','-md=1m'])
seven('encrypted.7z',['-t7z','-ms=off','-md=1m','-mhe=on','-pcomic-test'])
seven('encrypted-data.7z',['-t7z','-ms=off','-md=1m','-mhe=off','-pcomic-test'])
seven('solid.7z',['-t7z','-ms=on','-md=1m'])
for name,args in [('plain.rar',['-s-']),('encrypted.rar',['-s-','-hpcomic-test']),('solid.rar',['-s']),
                  ('quickopen.rar',['-s-', '-qo+']),
                  ('quickopen-encrypted-data.rar',['-s-', '-qo+', '-pcomic-test'])]:
    out=root/name
    if out.exists(): out.unlink()
    subprocess.run([a.rar,'a','-idq','-ma5',*args,str(out),'*.png'],cwd=source,check=True)
tree = root / 'tree'
for folder in ['chapter2', 'chapter10', 'empty']:
    (tree / folder).mkdir(parents=True, exist_ok=True)
for target, number in [('cover.png', 1), ('chapter2/2.png', 2), ('chapter10/10.png', 10)]:
    (tree / target).write_bytes((source / f'{number}.png').read_bytes())
(tree / 'readme.txt').write_text('Synthetic directory fixture', encoding='utf-8')
for name, args in [('tree.zip', ['-tzip']), ('tree-aes.zip', ['-tzip', '-pcomic-test', '-mem=AES256']),
                   ('tree.7z', ['-t7z', '-ms=off', '-md=1m']),
                   ('tree-encrypted.7z', ['-t7z', '-ms=off', '-md=1m', '-mhe=on', '-pcomic-test'])]:
    out = root / name
    if out.exists(): out.unlink()
    subprocess.run([a.sevenzip, 'a', '-y', '-bd', *args, str(out), '-r', '*'], cwd=tree, check=True, stdout=subprocess.DEVNULL)
for name, args in [('tree.rar', ['-s-']), ('tree-encrypted.rar', ['-s-', '-hpcomic-test'])]:
    out = root / name
    if out.exists(): out.unlink()
    subprocess.run([a.rar, 'a', '-idq', '-ma5', *args, '-r', str(out), '*'], cwd=tree, check=True)
print(root)
