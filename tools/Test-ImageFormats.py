"""Run the production decoder core on the public corpus; no ADB, APK or user media."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import io
import numpy as np
from PIL import Image, ImageOps

ROOT=Path(__file__).resolve().parent.parent


def linux(path):
    value=str(Path(path).resolve()).replace('\\','/')
    return '/mnt/'+value[0].lower()+value[2:] if len(value)>2 and value[1]==':' else value


def gif_reference(path):
    """Independent frame composition, using Pillow only for isolated LZW images.

    GIF89a defines background as a GLOBAL palette index. Pillow's coalescer uses
    a local palette for one dispose_bgnd fixture, so its full-canvas output is not
    the oracle for that rule. Rectangles, transparency and disposal are explicit.
    """
    data=Path(path).read_bytes();header=data[:13];w=int.from_bytes(data[6:8],'little');h=int.from_bytes(data[8:10],'little')
    size=3*(2**((data[10]&7)+1)) if data[10]&128 else 0
    palette=data[13:13+size];background=tuple(palette[data[11]*3:data[11]*3+3])+(255,) if size else (0,0,0,0)
    at=13+size;gce=b'';canvas=None;frames=[]
    def subblocks(pos):
        while True:
            n=data[pos];pos+=1
            if not n:return pos
            pos+=n
    while at<len(data):
        tag=data[at]
        if tag==0x3b:break
        if tag==0x21:
            end=subblocks(at+2)
            if data[at+1]==0xf9:gce=data[at:end]
            at=end;continue
        if tag!=0x2c:raise ValueError('Invalid GIF block')
        desc=bytearray(data[at:at+10]);left=int.from_bytes(desc[1:3],'little');top=int.from_bytes(desc[3:5],'little')
        fw=int.from_bytes(desc[5:7],'little');fh=int.from_bytes(desc[7:9],'little')
        local=3*(2**((desc[9]&7)+1)) if desc[9]&128 else 0
        end=subblocks(at+10+local+1)
        flags=gce[3] if gce else 0;transparent=bool(flags&1);disposal=(flags>>2)&7
        if canvas is None:canvas=Image.new('RGBA',(w,h),(0,0,0,0) if transparent else background)
        before=canvas.copy();logical=bytearray(header);logical[6:8]=fw.to_bytes(2,'little');logical[8:10]=fh.to_bytes(2,'little')
        # A single-frame Pillow image can select the original global palette even
        # when that rectangle has a local one. Give the isolated file just its
        # effective palette so the oracle only delegates LZW/palette expansion.
        effective=data[at+10:at+10+local] if local else palette
        logical[10]=(logical[10]&0x70)|0x80|((desc[9] if local else header[10])&7)
        desc[1:5]=bytes(4);desc[9]&=0x7f;control=bytearray(gce)
        if control:control[3]&=~0x1c
        single=bytes(logical)+effective+bytes(control)+bytes(desc)+data[at+10+local:end]+b'\x3b'
        with Image.open(io.BytesIO(single)) as image:
            canvas.alpha_composite(image.convert('RGBA'),(left,top))
        frames.append(canvas.copy())
        if disposal==2:canvas.paste((0,0,0,0) if transparent else background,(left,top,left+fw,top+fh))
        elif disposal==3:canvas=before
        gce=b'';at=end
    return frames


def hdr_reference(path,metadata):
    """Independent float64 ST2084/HLG, primary conversion and SDR mapping.

    Input is full precision encoded RGB from libavif before product color code.
    Pillow's 8-bit HDR RGB loses precision before PQ and cannot be this oracle.
    """
    data=np.fromfile(path,dtype='<u2').reshape(metadata['height'],metadata['width'],4)
    x=data[:,:,:3].astype(float)/65535
    if metadata['transfer']==16:
        p=np.power(x,1/78.84375)
        rgb=100*np.power(np.maximum(p-.8359375,0)/np.maximum(18.8515625-18.6875*p,1e-9),1/.1593017578125)
    else:
        rgb=np.where(x<=.5,x*x/3,(np.exp((x-.55991073)/.17883277)+.28466892)/12)*10
    matrix=np.array([[1.224745,-.224904,0],[-.042058,1.042081,0],[-.019642,-.078655,1.098537]]) if metadata['primaries']==12 else np.array([[1.660491,-.587641,-.072850],[-.124550,1.132900,-.008349],[-.018151,-.100579,1.118730]])
    rgb=rgb@matrix.T;lum=np.maximum(rgb@np.array([.2126,.7152,.0722]),0)
    rgb=np.maximum(rgb/(1+lum[:,:,None]),0)
    output=np.empty(data.shape,dtype=np.uint8)
    output[:,:,:3]=np.round(np.clip(np.where(rgb<=.0031308,12.92*rgb,1.055*np.power(rgb,1/2.4)-.055),0,1)*255)
    output[:,:,3]=np.round(data[:,:,3]/257)
    return output


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--fixtures',type=Path,required=True)
    parser.add_argument('--output',type=Path,default=ROOT/'build/output/image-formats/core')
    args=parser.parse_args();out=args.output.resolve();out.mkdir(parents=True,exist_ok=True)
    # Optional independent AV1 backend, installed in a disposable directory, never the product.
    sys.path.insert(0,str(ROOT/'tmp/image-reference'))
    try:
        import pillow_avif
        from pillow_avif import AvifImagePlugin,_avif
        AvifImagePlugin.DECODE_CODEC_CHOICE='aom' if _avif.decoder_codec_available('aom') else 'auto'
        avif_reference={'codec':AvifImagePlugin.DECODE_CODEC_CHOICE,'versions':str(_avif.codec_versions())}
    except ImportError:
        avif_reference=None
    if avif_reference is None:
        raise SystemExit('AVIF reference missing: install pillow-avif-plugin==1.6.0 into tmp/image-reference before running the complete suite.')
    sources=json.loads((args.fixtures/'SOURCES.json').read_text(encoding='utf-8'))
    cases=[]
    for i,item in enumerate(sources):
        relative=Path(item['path']);group=relative.parts[0]
        cases.append({'index':i,'file':linux(args.fixtures/relative),'output':linux(out/f'case-{i}'),
                      'group':group,'name':relative.name,'edge':8192 if group!='RAW' else 2048,'invalid':group in ('Invalid','Unsupported')})
    batch=out/'cases.json';batch.write_text(json.dumps(cases),encoding='utf-8')
    runner="""import json,subprocess,sys
from pathlib import Path
cases=json.loads(Path(sys.argv[1]).read_text())
results=[]
for c in cases:
 r=subprocess.run([sys.argv[2],c['file'],c['output'],str(c['edge'])],capture_output=True,text=True,timeout=180)
 c['exit_code']=r.returncode;c['stderr']=r.stderr[-4000:];c['frames']=[json.loads(line) for line in r.stdout.splitlines() if line.startswith('{')]
 if c['group']=='AVIF' and 'hdr' in c['name'] and r.returncode==0:
  ref=subprocess.run([sys.argv[2],c['file'],c['output'],'8192','encoded16'],capture_output=True,text=True,timeout=60,check=True)
  c['encoded_color']=json.loads(ref.stdout)
 results.append(c);print(c['index'],c['name'],r.returncode,len(c['frames']),flush=True)
Path(sys.argv[3]).write_text(json.dumps(results),encoding='utf-8')
"""
    result_path=out/'decoder.json'
    subprocess.run(['wsl.exe','-e','python3','-c',runner,linux(batch),linux(ROOT/'build/image-host-linux/core/image_probe'),linux(result_path)],check=True)
    results=json.loads(result_path.read_text(encoding='utf-8'));failures=[]
    for case,item in zip(results,sources):
        name=case['name'];case['checks']=[]
        def check(value,message):
            case['checks'].append({'check':message,'pass':bool(value)})
            if not value:failures.append(name+': '+message)
        if case['invalid']:
            check(case['exit_code']!=0,'Malformed input rejected')
            continue
        check(case['exit_code']==0 and bool(case['frames']),'Decode produces frames')
        if case['exit_code'] or not case['frames']:continue
        file=args.fixtures/item['path']
        if case['group']=='RAW':
            check(len(case['frames'])==1,'RAW is a single picture')
            check(not case['frames'][0]['preview'],'Sensor RAW decoded, not embedded JPEG')
            continue
        if case['group']=='AVIF' and avif_reference is None:continue
        with Image.open(file) as reference:
            gif=gif_reference(file) if case['group']=='GIF' else None
            default=1 if reference.info.get('default_image') else 0
            check(len(case['frames'])==reference.n_frames-default,'Animation frame count')
            if case['group'] in ('GIF','APNG','WEBP'):
                repeat=reference.info.get('loop',1 if case['group']!='GIF' else -1)
                plays=(1 if repeat==-1 else 0 if repeat==0 else repeat+1) if case['group']=='GIF' else repeat
                check(case['frames'][0]['plays']==plays,'Finite/infinite loop count normalized')
            if 'expected_plays' in item:
                check(case['frames'][0]['plays']==item['expected_plays'],'Explicit finite animation play count')
            for n,frame in enumerate(case['frames']):
                if n+default>=reference.n_frames:break
                reference.seek(n+default);expected=gif[n] if gif is not None else ImageOps.exif_transpose(reference).convert('RGBA')
                check((frame['width'],frame['height'])==expected.size,f'Frame {n} dimensions and direction')
                duration=reference.info.get('duration')
                if duration and duration>=20:check(abs(frame['duration_us']-round(duration*1000))<=1000,f'Frame {n} duration')
                if (frame['width'],frame['height'])!=expected.size:continue
                actual=np.fromfile(out/f"case-{case['index']}-{n}.rgba",dtype=np.uint8).reshape(frame['height'],frame['width'],4)
                wanted=np.asarray(expected);visible=(actual[:,:,3]>0)|(wanted[:,:,3]>0)
                alpha_error=int(np.abs(actual[:,:,3].astype(np.int16)-wanted[:,:,3]).max())
                check(alpha_error<=1,f'Frame {n} alpha')
                if 'encoded_color' in case:
                    wanted=hdr_reference(out/f"case-{case['index']}.rgba16",case['encoded_color'])
                error=np.abs(actual.astype(np.int16)-wanted.astype(np.int16))
                maximum=int(error[visible].max()) if np.any(visible) else 0
                mean=float(error[visible].mean()) if np.any(visible) else 0.0
                frame['pixel_error']={'max':maximum,'mean':mean}
                # The 12-bit reference uses libyuv's integer 8-bit conversion; production converts
                # at 16 bits before quantizing. Bound both peak error and average rounding error.
                high_depth=case['group']=='AVIF' and '12bpc' in name
                tolerance=4 if high_depth else 3 if case['group']=='AVIF' else 1
                check(maximum<=tolerance and (not high_depth or mean<0.6),f'Frame {n} composited pixels (max {maximum})')
    report={'scope':'Production C++ core host decoding; no Android/GPU/XR device acceptance',
            'avif_reference':avif_reference,'cases':results,'failures':failures}
    (out/'verification.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({'cases':len(results),'checks':sum(len(c['checks']) for c in results),'failures':failures},ensure_ascii=False))
    if failures:raise SystemExit(1)


if __name__=='__main__':main()
