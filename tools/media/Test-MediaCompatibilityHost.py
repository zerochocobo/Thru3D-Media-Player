"""Compare normal AVC/HEVC MP4/MKV and packed stereo with an independent FFmpeg.

Generated test patterns only. Run inside the Linux build environment; a Windows
reference FFmpeg is supported through WSL interop. Every decoded byte is hashed
as a stream, without retaining raw movie frames.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--binary-dir',type=Path,required=True)
p.add_argument('--reference-ffmpeg',type=Path,required=True)
p.add_argument('--preflight',type=Path,required=True)
p.add_argument('--output',type=Path,required=True)
a=p.parse_args();a.output.mkdir(parents=True,exist_ok=True)
env=dict(os.environ,LD_LIBRARY_PATH=':'.join(str(a.binary_dir/lib) for lib in
    ('libavcodec','libavformat','libavutil','libswresample','libswscale','libavfilter','libavdevice')))
windows=a.reference_ffmpeg.suffix.lower()=='.exe'
def refpath(path):
    return subprocess.check_output(['wslpath','-w',str(path.resolve())],text=True).strip() if windows else str(path)
cases=[]
for name,codec,extension,mode in (
    ('avc-mp4','libx264','mp4',''),('avc-mkv','libx264','mkv',''),
    ('hevc-mp4','libx265','mp4',''),('hevc-mkv','libx265','mkv',''),
    ('sbs-mkv','libx264','mkv','left_right'),('tb-mkv','libx264','mkv','top_bottom')):
    path=a.output/(name+'.'+extension)
    command=[str(a.reference_ffmpeg),'-nostdin','-v','error','-f','lavfi','-i','testsrc2=size=640x360:rate=24',
        '-f','lavfi','-i','sine=frequency=440:sample_rate=48000','-t','3','-c:v',codec,'-threads','2','-pix_fmt','yuv420p','-c:a','ac3']
    if codec=='libx265':command+=['-x265-params','log-level=error:pools=2']
    if mode:
        command+=['-vf', 'split[a][b];[a][b]'+('hstack' if mode=='left_right' else 'vstack'),'-metadata:s:v:0','stereo_mode='+mode]
    command+=['-y',refpath(path)]
    result=subprocess.run(command,capture_output=True,timeout=120)
    (a.output/(name+'-encode.log')).write_bytes(result.stderr)
    assert result.returncode==0,name
    hashes=[];sizes=[]
    for kind,binary,source in [('reference',a.reference_ffmpeg,refpath(path)),('candidate',a.binary_dir/'ffmpeg',str(path))]:
        with (a.output/(name+'-'+kind+'.log')).open('wb') as log:
            target = 'file:/dev/stdout' if kind=='candidate' else '-'
            proc=subprocess.Popen([str(binary),'-nostdin','-v','error','-i',source,'-map','0:v:0','-an','-pix_fmt','yuv420p','-f','rawvideo','-y',target],
                stdout=subprocess.PIPE,stderr=log,env=env)
            digest=hashlib.sha256();total=0
            while data:=proc.stdout.read(65536):digest.update(data);total+=len(data)
            assert proc.wait(timeout=30)==0,(name,kind)
            hashes.append(digest.hexdigest());sizes.append(total)
    assert sizes[0]>0 and sizes[0]==sizes[1] and hashes[0]==hashes[1],(name,sizes,hashes)
    probe=subprocess.run([str(a.binary_dir/'ffprobe'),'-v','error','-select_streams','v:0','-show_entries','stream=codec_name,width,height:stream_tags=stereo_mode','-of','json',str(path)],env=env,capture_output=True,timeout=20)
    assert not probe.returncode
    video=json.loads(probe.stdout)['streams'][0]
    assert video['codec_name']==('hevc' if codec=='libx265' else 'h264'),video
    if mode:assert video['tags']['stereo_mode']==mode,video
    if extension=='mkv':
        pre=subprocess.run([str(a.preflight),str(path)],env=env,capture_output=True,timeout=20)
        assert not pre.returncode and not json.loads(pre.stdout)['mvc'],name
    null=subprocess.run([str(a.binary_dir/'ffmpeg'),'-nostdin','-v','error','-ss','1','-i',str(path),'-t','1',
        '-map','0:v:0','-map','0:a:0','-f','null','-'],env=env,capture_output=True,timeout=30)
    assert not null.returncode and not null.stderr,(name,null.stderr)
    cases.append(dict(case=name,decoded_bytes=sizes[0],sha256=hashes[0],video=video,seek_audio_passed=True))
# A large font/cover must not make ordinary playback fail the 8-MiB probe bound.
attachment=a.output/'large-attachment.bin';attachment.write_bytes(bytes(12*1024*1024))
attached=a.output/'avc-large-attachment.mkv'
encode=subprocess.run([str(a.reference_ffmpeg),'-nostdin','-v','error','-i',refpath(a.output/'avc-mkv.mkv'),
    '-map','0','-c','copy','-attach',refpath(attachment),'-metadata:s:t:0','mimetype=application/octet-stream','-y',refpath(attached)],capture_output=True,timeout=30)
assert not encode.returncode,encode.stderr
pre=subprocess.run([str(a.preflight),str(attached)],env=env,capture_output=True,timeout=20)
assert not pre.returncode,pre.stderr
header=json.loads(pre.stdout)
assert not header['mvc'] and header['header_bytes']<1024*1024,header
cases.append(dict(case='large-attachment-header',**header))
(a.output/'result.json').write_text(json.dumps(cases,indent=2)+'\n')
print(json.dumps(cases,indent=2),flush=True)
