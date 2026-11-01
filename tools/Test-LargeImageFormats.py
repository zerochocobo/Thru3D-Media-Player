"""Generated large-photo and memory-pressure regression; no APK, ADB or personal photos."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import zlib

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'tmp/image-reference'))


def linux(path):
    value = str(Path(path).resolve()).replace('\\', '/')
    return '/mnt/' + value[0].lower() + value[2:] if len(value) > 2 and value[1] == ':' else value


def generate(directory):
    import pillow_avif  # Host encoder only; never an application dependency.
    import numpy as np
    import tifffile
    from PIL import Image, ImageDraw
    directory.mkdir(parents=True, exist_ok=True)
    for width, height in ((6000, 6000), (10000, 10000)):
        path = directory / f'original-{width}x{height}.avif'
        if path.exists():
            continue
        image = Image.new('RGB', (width, height), (220, 40, 30))
        draw = ImageDraw.Draw(image)
        draw.rectangle((width//2, 0, width-1, height//2-1), fill=(30, 210, 50))
        draw.rectangle((0, height//2, width//2-1, height-1), fill=(30, 50, 220))
        draw.rectangle((width//2, height//2, width-1, height-1), fill=(230, 220, 30))
        image.save(path, quality=95, speed=10, codec='aom', max_threads=2)
        image.close()
        print('Generated', path.name, flush=True)
    def pattern(size):
        w,h=size; image=Image.new('RGB',size,(220,40,30)); draw=ImageDraw.Draw(image)
        draw.rectangle((w//2,0,w-1,h//2-1),fill=(30,210,50))
        draw.rectangle((0,h//2,w//2-1,h-1),fill=(30,50,220))
        draw.rectangle((w//2,h//2,w-1,h-1),fill=(230,220,30))
        return image
    for suffix, options in [('avif',dict(codec='aom',quality=95,speed=10,max_threads=2)),
                            ('gif',{}),('webp',dict(lossless=True)),('png',{})]:
        path=directory/f'animation-20mp.{suffix}'
        if path.exists():continue
        first=pattern((5000,4000)); second=first.copy()
        ImageDraw.Draw(second).rectangle((2400,1900,2600,2100),fill='white')
        first.save(path,save_all=True,append_images=[second],duration=100,loop=0,**options)
        first.close();second.close();print('Generated',path.name,flush=True)
    path=directory/'animation-36mib-metadata.png'
    if not path.exists():
        first=pattern((512,256));second=first.copy();ImageDraw.Draw(second).point((0,0),fill='white')
        first.save(path,save_all=True,append_images=[second],duration=100,loop=0)
        data=path.read_bytes(); payload=b'vpAg'+bytes(36*1024*1024)
        chunk=(len(payload)-4).to_bytes(4,'big')+payload+zlib.crc32(payload).to_bytes(4,'big')
        path.write_bytes(data[:33]+chunk+data[33:]);first.close();second.close()
        print('Generated',path.name,flush=True)
    # A real uncompressed Bayer DNG with a small RGB thumbnail. The sensor's
    # 140MP dimensions exceed the former 128Mi-pixel metadata cap.
    path = directory / 'original-140mp-with-preview.dng'
    if not path.exists():
        tags = [(50706, 'B', 4, (1, 4, 0, 0), False),
                (50707, 'B', 4, (1, 1, 0, 0), False),
                (271, 's', 0, 'Thru3D', False), (272, 's', 0, 'Generated CFA', False),
                (50708, 's', 0, 'Thru3D Generated CFA', False)]
        raw_tags = [(33421, 'H', 2, (2, 2), False),
                    (33422, 'B', 4, (0, 1, 1, 2), False),
                    (50714, 'H', 1, 0, False), (50717, 'I', 1, 65535, False),
                    (50721, '2i', 9, (1,1,0,1,0,1,0,1,1,1,0,1,0,1,0,1,1,1), False),
                    (50728, '2I', 3, (1,1,1,1,1,1), False),
                    (50778, 'H', 1, 21, False)]
        with tifffile.TiffWriter(path) as writer:
            writer.write(np.full((64, 128, 3), (40, 160, 220), dtype=np.uint8),
                         photometric='rgb', subfiletype=1, subifds=1, metadata=None, extratags=tags)
            writer.write(data=None, shape=(10000, 14000), dtype='uint16', photometric=32803,
                         metadata=None, extratags=raw_tags)
        print('Generated', path.name, flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, default=ROOT/'build/output/large-image-formats')
    parser.add_argument('--generate-only', action='store_true')
    args = parser.parse_args()
    out = args.output.resolve(); fixtures = out/'fixtures'
    generate(fixtures)
    if args.generate_only:
        return
    cases = [
        ('36mp', 'original-6000x6000.avif', 1024, 512, 32, True),
        ('100mp', 'original-10000x10000.avif', 1024, 1024, 32, True),
        ('100mp-auto-reduce', 'original-10000x10000.avif', 8192, 512, 128, True),
        ('avif20mp-animation', 'animation-20mp.avif', 1024, 512, 32, True),
        ('gif20mp-animation', 'animation-20mp.gif', 1024, 512, 32, True),
        ('webp20mp-animation', 'animation-20mp.webp', 1024, 512, 32, True),
        ('apng20mp-animation', 'animation-20mp.png', 1024, 512, 32, True),
        ('apng36mib', 'animation-36mib-metadata.png', 1024, 512, 32, True),
        ('small-output', 'original-6000x6000.avif', 8192, 512, 4, True),
        ('low-memory', 'original-6000x6000.avif', 1024, 16, 4, False),
        ('no-output-memory', 'original-6000x6000.avif', 1024, 512, 0, False),
        ('raw140-preview', 'original-140mp-with-preview.dng', 1024, 128, 16, True),
        ('raw-no-memory', 'original-140mp-with-preview.dng', 1024, 0, 0, False),
        ('recovery', 'original-6000x6000.avif', 1024, 512, 32, True),
    ]
    results = []; failures = []
    for name, file, edge, memory, output, success in cases:
        cmd = ['wsl.exe', '-d', 'QuestMpvBuild', '-e',
               linux(ROOT/'build/image-host-linux/core/image_probe'), linux(fixtures/file),
               linux(out/name), str(edge), 'recover' if name == 'recovery' else 'full', str(memory), str(output)]
        run = subprocess.run(cmd, capture_output=True, text=True, timeout=240)
        frames = [json.loads(line) for line in run.stdout.splitlines() if line.startswith('{')]
        passed = run.returncode == 0 and bool(frames) if success else (
            run.returncode == 1 and 'PHOTO_OUT_OF_MEMORY' in run.stderr)
        if passed and success:
            frame = frames[0]
            passed = frame['width']*frame['height']*4 <= output*1024*1024
            if name.startswith('raw'):
                passed = passed and frame['preview']
            else:
                import numpy as np
                pixels = np.fromfile(out/f'{name}-0.rgba', dtype=np.uint8).reshape(frame['height'], frame['width'], 4)
                expected = [(220,40,30),(30,210,50),(30,50,220),(230,220,30)]
                for (x,y), color in zip(((.25,.25),(.75,.25),(.25,.75),(.75,.75)), expected):
                    pixel = pixels[int(y*frame['height']),int(x*frame['width'])]
                    passed = passed and max(abs(int(a)-b) for a,b in zip(pixel[:3],color)) <= 4 and pixel[3] == 255
        results.append(dict(name=name, passed=bool(passed), exit_code=run.returncode,
                            memory_mib=memory, output_mib=output, frames=frames, stderr=run.stderr[-1500:]))
        if not passed:
            failures.append(name)
        print(name, 'PASS' if passed else 'FAIL', flush=True)
    (out/'verification.json').write_text(json.dumps(dict(scope='Production host core; generated inputs and injected headroom, no headset acceptance',
        cases=results, failures=failures), ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    if failures:
        raise SystemExit(str(failures))


if __name__ == '__main__':
    main()
