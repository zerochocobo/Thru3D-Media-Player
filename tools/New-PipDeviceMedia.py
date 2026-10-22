"""Generate reproducible local PiP identity videos; requires FFmpeg, numpy and Pillow."""
import argparse
from pathlib import Path
import json, subprocess
import numpy as np
from PIL import Image

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output',type=Path,default=Path('build/output/video-pip/fixtures'))
parser.add_argument('--ffmpeg',default='ffmpeg')
parser.add_argument('--large',action='store_true',help='Also generate a correctly repacked 8192x4096 Alpha stress clip')
parser.add_argument('--large-codec',default='libx265',choices=('libx265','hevc_nvenc'))
args=parser.parse_args()
out=args.output; out.mkdir(parents=True,exist_ok=True)
root=Path(__file__).resolve().parents[1]
subtitle=out/'pip_subtitles.srt'
subtitle.write_text('1\n00:00:00,000 --> 00:00:02,900\nPiP source A\n\n2\n00:00:03,000 --> 00:00:06,000\nPiP source B\n',encoding='utf-8')
for layout in ('sbs','tb'):
    w,h=(1280,640) if layout=='sbs' else (640,1280)
    path=out/f'pip_identity_{layout}.mp4'
    cmd=[args.ffmpeg,'-v','error','-y','-f','rawvideo','-pix_fmt','rgb24','-s',f'{w}x{h}','-r','30','-i','pipe:0',
         '-f','lavfi','-i','sine=frequency=440:sample_rate=48000','-i',str(subtitle),'-map','0:v','-map','1:a','-map','2:s',
         '-vf','scale=out_color_matrix=bt709,format=yuv420p','-colorspace','bt709','-color_primaries','bt709','-color_trc','bt709',
         '-c:v','libx264','-preset','veryfast','-tune','zerolatency','-crf','12','-g','30','-threads','4',
         '-c:a','aac','-b:a','96k','-c:s','mov_text','-t','6','-movflags','+faststart',str(path)]
    p=subprocess.Popen(cmd,stdin=subprocess.PIPE)
    for n in range(180):
        left=np.empty((640,640,3),dtype=np.uint8); right=np.empty_like(left)
        left[:]=(128+(n%32)*3,60,40); right[:]=(40,60,128+(n%32)*3)
        for eye in (left,right):
            for k in (128,256,384,512):
                eye[k:k+2,:]=(230,230,230); eye[:,k:k+2]=(230,230,230)
            # A source-only title stripe; it should never appear as a duplicated UI.
            eye[10:35,15:125]=(70,150,70)
        frame=np.concatenate((left,right),axis=1 if layout=='sbs' else 0)
        p.stdin.write(frame.tobytes())
    p.stdin.close()
    assert p.wait()==0
    print(path)
packed=out/'pip_FISHEYE_F180_alpha.mp4'
rgb=np.array(Image.open(root/'app/godot/media/c04_alpha_f180_rgb.png').convert('RGB'))
mask_w,mask_h=512,256
my,mx=np.mgrid[:mask_h,:mask_w]
sy=np.where(my<mask_h//2,rgb.shape[0]-mask_h//2+my,my-mask_h//2)
sx=np.where(mx<mask_w//2,rgb.shape[1]//2-mask_w//4+mx,
    np.where(mx<3*mask_w//4,rgb.shape[1]-mask_w//4+mx-mask_w//2,mx-3*mask_w//4))
# A constant mask avoids discontinuities at tile boundaries and allows different
# PiP magnifications to be compared at their actual pixel centres. Neutral RGB
# also avoids chroma-subsampling artefacts in the red channel carrying the mask.
rgb[sy,sx]=128
packed_rgb=out/'pip_constant_packed_rgb.png'; Image.fromarray(rgb).save(packed_rgb)
subprocess.run([args.ffmpeg,'-v','error','-y','-loop','1','-i',str(packed_rgb),'-t','6',
                '-vf','scale=out_color_matrix=bt709,format=yuv420p','-r','30','-c:v','libx264','-preset','veryfast',
                '-crf','8','-g','30','-threads','4','-colorspace','bt709','-color_trc','bt709','-color_primaries','bt709',
                '-movflags','+faststart',str(packed)],check=True)
reference=np.array(Image.open(root/'app/godot/media/c04_packed_mask_oracle.png').convert('L'))
(out/'manifest.json').write_text(json.dumps({'fps':30,'seconds':6,'identity':'left=(128+3*(frame%32),60,40), right=(40,60,128+3*(frame%32))',
    'packed_center_alpha':[int(reference[reference.shape[0]//2,reference.shape[1]//4]),int(reference[reference.shape[0]//2,3*reference.shape[1]//4])]},indent=2))
print(packed)
if args.large:
    large=np.array(Image.fromarray(rgb).resize((8192,4096),Image.Resampling.NEAREST))
    mw,mh=3276,1638 # round(width*.4)&~3, round(height*.4)&~1
    my,mx=np.mgrid[:mh,:mw]
    sy=np.where(my<mh//2,4096-mh//2+my,my-mh//2)
    sx=np.where(mx<mw//2,8192//2-mw//4+mx,
        np.where(mx<3*mw//4,8192-mw//4+mx-mw//2,mx-3*mw//4))
    large[sy,sx]=128
    large_png=out/'pip_8k_packed_rgb.png';Image.fromarray(large).save(large_png)
    large_video=out/'pip_8k_FISHEYE_F180_alpha.mp4'
    codec=['-c:v','hevc_nvenc','-preset','p1','-cq','18'] if args.large_codec=='hevc_nvenc' else ['-c:v','libx265','-preset','ultrafast','-crf','18','-threads','8']
    subprocess.run([args.ffmpeg,'-v','error','-y','-loop','1','-i',str(large_png),'-t','6','-r','30',
        '-vf','scale=out_color_matrix=bt709,format=yuv420p',*codec,'-g','30','-colorspace','bt709',
        '-color_trc','bt709','-color_primaries','bt709','-movflags','+faststart',str(large_video)],check=True)
    print(large_video)
