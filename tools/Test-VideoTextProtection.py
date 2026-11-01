"""Host build/run of the production Tiny-only C++ core. Synthetic subtitle fixtures, not device claims.
Outputs (regenerable): build/output/text-protection/native-host and detector-review.
"""
import ctypes
import hashlib
import json
import os
from pathlib import Path
import subprocess
import numpy as np
from PIL import Image, ImageDraw, ImageFont
import onnxruntime

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/output/text-protection/native-host'
OUT.mkdir(parents=True,exist_ok=True)
vc=Path('C:/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/VC/Auxiliary/Build/vcvars64.bat')
dll=OUT/'text_detector.dll'
command=OUT/'compile.cmd'
command.write_text(f'@echo off\ncall "{vc}" >nul 2>nul\nif errorlevel 1 exit /b 1\n'
    f'cl /nologo /LD /std:c++17 /O2 /EHsc /utf-8 /W3 /WX /I"{ROOT/"tmp/narration-deps"}" '
    f'/I"{ROOT/"native/narration"}" /Fo"{OUT/"text_detector.obj"}" /Fe"{dll}" "{ROOT/"native/narration/text_detector.cpp"}"\n',encoding='utf-8')
process=subprocess.run(['cmd','/c',str(command)],cwd=OUT,capture_output=True)
(OUT/'compile.log').write_bytes(process.stdout+process.stderr)
if process.returncode:raise RuntimeError((process.stdout+process.stderr).decode('utf-8','replace'))
ort=Path(onnxruntime.__file__).parent/'capi'
directory=os.add_dll_directory(str(ort));runtime=ctypes.WinDLL(str(ort/'onnxruntime.dll'))
core=ctypes.CDLL(str(dll))
core.text_detector_create.argtypes=[ctypes.c_char_p];core.text_detector_create.restype=ctypes.c_int64
core.text_detector_cancel.argtypes=[ctypes.c_int64,ctypes.c_int64]
core.text_detector_run.argtypes=[ctypes.c_int64,ctypes.POINTER(ctypes.c_float),ctypes.c_int,ctypes.c_int,ctypes.c_int64]
core.text_detector_run.restype=ctypes.c_void_p
core.text_detector_free.argtypes=[ctypes.c_void_p];core.text_detector_destroy.argtypes=[ctypes.c_int64]
manifest=json.loads((ROOT/'third_party/text-protection/model.json').read_text('utf-8'))
model=ROOT/'models/text-protection'/manifest['id']/'multi_PP-OCRv6_det_tiny.onnx'
assert hashlib.sha256(model.read_bytes()).hexdigest()==manifest['files'][model.name]['sha256']
handle=core.text_detector_create(str(model).encode());assert handle>0
core.text_detector_cancel(handle,1)
def run(rgb,token=1,w=640,h=352):
    data=np.ascontiguousarray(rgb,np.float32)
    pointer=core.text_detector_run(handle,data.ctypes.data_as(ctypes.POINTER(ctypes.c_float)),w,h,token)
    try:return json.loads(ctypes.string_at(pointer).decode())
    finally:core.text_detector_free(pointer)

review=ROOT/'build/output/text-protection/detector-review';review.mkdir(parents=True,exist_ok=True)
font=ImageFont.truetype('C:/Windows/Fonts/msyh.ttc',38)
fixtures=[('english','Burned-in subtitles stay readable',(255,255,255),580),
          ('chinese','硬字幕保护，保持文字清晰',(255,255,255),600),
          ('japanese','映像の字幕を読みやすく保護する',(255,230,0),600),
          ('top','Upper subtitle line',(255,255,255),65)]
reports=[]
for name,text,fill,y in fixtures:
    yy,xx=np.mgrid[:720,:1280];background=np.stack([(xx//7+yy//9)%65+30,(yy//5)%80+40,(xx//11)%70+50],axis=2).astype(np.uint8)
    image=Image.fromarray(background);draw=ImageDraw.Draw(image)
    bounds=draw.textbbox((0,0),text,font=font,stroke_width=2)
    x=(1280-bounds[2])/2
    expected=draw.textbbox((x,y),text,font=font,stroke_width=2)
    draw.text((x,y),text,font=font,fill=fill,stroke_width=2,stroke_fill=(0,0,0))
    small=image.resize((640,352),Image.Resampling.BOX)
    data=np.asarray(small,np.float32).transpose(2,0,1)/255
    result=run(data);assert result['state']=='ready',result
    boxes=result['boxes']
    area=(expected[2]-expected[0])*(expected[3]-expected[1])
    cover=0
    for box in boxes:
        rect=[box[0]*1280,box[1]*720,box[2]*1280,box[3]*720]
        cover+=max(0,min(rect[2],expected[2])-max(rect[0],expected[0]))*max(0,min(rect[3],expected[3])-max(rect[1],expected[1]))
        draw.rectangle(rect,outline=(0,255,120),width=2)
    coverage=min(1,cover/area)
    assert coverage>.85,(name,coverage,boxes)
    image.save(review/f'{name}.png')
    reports.append({'case':name,'coverage':coverage,'result':result})
blank=np.zeros((3,352,640),np.float32)
assert run(blank)['boxes']==[]
assert run(blank,token=2)['error']=='cancelled'
core.text_detector_cancel(handle,2)
assert run(blank,token=2)['state']=='ready'
invalid=blank.copy();invalid[0,0,0]=np.nan
assert run(invalid,token=2)['error']=='text_input_range'
assert run(blank,token=2,w=639)['error']=='text_input_size'
core.text_detector_destroy(handle)
assert run(blank,token=2)['error']=='closed'
core.text_detector_destroy(handle)
(review/'report.json').write_text(json.dumps({'scope':'Synthetic frames; production C++ CPU detector, no device performance or real-video recall claim','fixtures':reports,'lifecycle_checks':6,'source_sha256':hashlib.sha256((ROOT/'native/narration/text_detector.cpp').read_bytes()).hexdigest()},ensure_ascii=False,indent=2),'utf-8')
print('Tiny production detector: 4 subtitle fixtures + blank + 6 lifecycle/range checks passed')
