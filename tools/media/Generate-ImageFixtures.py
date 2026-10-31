"""Add reproducible original motion/alpha/size tests to the public image corpus."""
import hashlib
import json
from pathlib import Path
import sys
import zlib

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tmp/image-reference'))
import pillow_avif  # Disposable host reference encoder, not an application dependency.
from PIL import Image,ImageDraw,ImageCms,PngImagePlugin


def main():
    target=ROOT/'build/output/image-fixtures'
    sources=json.loads((target/'SOURCES.json').read_text(encoding='utf-8'))
    sources=[s for s in sources if s.get('generator')!='tools/media/Generate-ImageFixtures.py']
    def save(group,name,frames,**options):
        path=target/group/name;path.parent.mkdir(parents=True,exist_ok=True)
        frames[0].save(path,**options)
        sources.append({'path':path.relative_to(target).as_posix(),'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),
            'bytes':path.stat().st_size,'source':'Original geometric acceptance patterns, generated locally',
            'generator':'tools/media/Generate-ImageFixtures.py','license':'CC0-1.0'})
    def frames(size,count):
        result=[]
        for i in range(count):
            image=Image.new('RGBA',size,(0,0,0,0));draw=ImageDraw.Draw(image);w,h=size
            draw.rectangle((0,h//2,w,h),fill=(24,50,100,255))
            x=round(i*(w-180)/max(1,count-1));draw.rectangle((x,30,x+150,h-60),fill=(255,80,40,128))
            draw.text((w//2-100,h-45),f'FRAME {i+1:02d} / {count:02d}',fill='white',font_size=26)
            draw.text((10,10),'TOP LEFT',fill=(20,255,80,255),font_size=22)
            result.append(image)
        return result
    small=frames((512,256),4);durations=[100,200,300,400]
    save('GIF','generated-timing-finite-2-plays.gif',small,save_all=True,append_images=small[1:],duration=durations,loop=1,disposal=2)
    save('GIF','generated-single-frame.gif',[small[0]])
    large=frames((1920,1080),12)
    save('APNG','generated-motion-1920x1080.png',large,save_all=True,append_images=large[1:],duration=100,loop=0,disposal=0,blend=0)
    text=PngImagePlugin.PngInfo();text.add_text('Comment','Large ancillary metadata before animation control: '+'x'*70000)
    save('APNG','generated-large-metadata-finite-2-plays.png',small,save_all=True,append_images=small[1:],duration=durations,loop=2,pnginfo=text)
    save('WEBP','generated-motion-1920x1080.webp',large,save_all=True,append_images=large[1:],duration=100,loop=0,lossless=True)
    exif=Image.Exif();exif[274]=6
    save('WEBP','generated-rotated-finite-2-plays.webp',small,save_all=True,append_images=small[1:],duration=durations,loop=2,lossless=True,exif=exif)
    save('AVIF','generated-motion-1920x1080.avif',large,save_all=True,append_images=large[1:],duration=100,loop=0,quality=95,speed=8,codec='aom')
    save('AVIF','generated-timing-finite-2-plays.avif',small,save_all=True,append_images=small[1:],duration=durations,loop=2,quality=95,speed=8,codec='aom')
    # pillow-avif's writer ignores loop. Set the standard edit-list track duration
    # to two sequence durations (libavif read/write.c, ISO/IEC 23008-12 §9.6.1).
    # Only fixed-width duration fields change; media offsets and samples stay intact.
    finite=target/'AVIF/generated-timing-finite-2-plays.avif';data=bytearray(finite.read_bytes())
    def boxes(start,end):
        result=[]
        while start+8<=end:
            size=int.from_bytes(data[start:start+4],'big');assert size>=8 and start+size<=end
            result.append((bytes(data[start+4:start+8]),start+8,start+size));start+=size
        return result
    moov=next(x for x in boxes(0,len(data)) if x[0]==b'moov')
    for tag,start,end in boxes(moov[1],moov[2]):
        if tag==b'trak':
            children=boxes(start,end);tkhd=next(x for x in children if x[0]==b'tkhd');edts=next(x for x in children if x[0]==b'edts')
            elst=next(x for x in boxes(edts[1],edts[2]) if x[0]==b'elst');width=8 if data[elst[1]] else 4
            segment=int.from_bytes(data[elst[1]+8:elst[1]+8+width],'big');offset=tkhd[1]+(28 if data[tkhd[1]] else 20);width=8 if data[tkhd[1]] else 4
            data[offset:offset+width]=(segment*2).to_bytes(width,'big')
        elif tag==b'mvhd':
            scale_at=start+(20 if data[start] else 12);scale=int.from_bytes(data[scale_at:scale_at+4],'big');width=8 if data[start] else 4
            data[scale_at+4:scale_at+4+width]=(scale*2).to_bytes(width,'big')
    finite.write_bytes(data);sources[-1].update(sha256=hashlib.sha256(data).hexdigest(),expected_plays=2)
    icc=ImageCms.ImageCmsProfile(ImageCms.createProfile('sRGB')).tobytes()
    save('AVIF','generated-icc-alpha.avif',[small[0]],quality=95,speed=8,codec='aom',icc_profile=icc)
    for source,name in [('GIF/generated-timing-finite-2-plays.gif','generated-oversize-canvas.gif'),
                        ('APNG/generated-large-metadata-finite-2-plays.png','generated-oversize-canvas.png'),
                        ('WEBP/generated-rotated-finite-2-plays.webp','generated-oversize-canvas.webp')]:
        data=bytearray((target/source).read_bytes())
        if name.endswith('.gif'):data[6:10]=b'\xff'*4
        elif name.endswith('.webp'):data[24:30]=b'\xff'*6
        else:
            data[16:20]=(65535).to_bytes(4,'big');data[20:24]=(65535).to_bytes(4,'big')
            data[29:33]=zlib.crc32(data[12:29]).to_bytes(4,'big')
        path=target/'Invalid'/name;path.write_bytes(data)
        sources.append({'path':path.relative_to(target).as_posix(),'sha256':hashlib.sha256(data).hexdigest(),'bytes':len(data),
            'source':'Original generated pattern with an oversized declared canvas; expected safe rejection',
            'generator':'tools/media/Generate-ImageFixtures.py','license':'CC0-1.0'})
    (target/'SOURCES.json').write_text(json.dumps(sources,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({'files':len(sources),'bytes':sum(s['bytes'] for s in sources)}))


if __name__=='__main__':main()
