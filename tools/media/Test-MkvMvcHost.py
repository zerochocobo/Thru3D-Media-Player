"""External-media MVC MKV regression: real decode, per-eye seek pixels and Range IO.

No movie bytes or frames enter the repository. Use the same FFmpeg candidate
sources as the player, rebuilt with build_mvc_host.sh (Matroska enabled).
"""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import subprocess
import threading
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('media', type=Path)
parser.add_argument('--binary-dir', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--ordinary', type=Path)
parser.add_argument('--expected-pairs', type=int, default=0)
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
args.output.mkdir(parents=True, exist_ok=True)
env = dict(os.environ, LD_LIBRARY_PATH=':'.join(str(args.binary_dir/lib) for lib in
    ('libavcodec','libavformat','libavutil','libswresample','libswscale','libavfilter','libavdevice')))
results = []

def run(label, command, timeout=180, success=True):
    value = subprocess.run(list(map(str,command)), env=env, capture_output=True, timeout=timeout)
    (args.output/(label+'.stdout.log')).write_bytes(value.stdout)
    (args.output/(label+'.stderr.log')).write_bytes(value.stderr)
    if success and value.returncode:
        raise RuntimeError(label+' failed; see independent log')
    return value

include = [args.binary_dir/'src', args.binary_dir]
link = [f'-L{args.binary_dir/lib}' for lib in ('libavformat','libavcodec','libavutil')]
for name, source, compiler, extra in (
    ('config',root/'benchmarks/native_mvc/mvc_config_test.c','cc',[]),
    ('preflight',root/'benchmarks/native_mvc/mkv_preflight_probe.cpp','c++',['-std=c++17']),
    ('seek',root/'benchmarks/native_mvc/iso_seek_recovery_probe.c','cc',[])):
    command = [compiler,'-O2','-Wall','-Wextra','-Werror',*extra,source,
               *[f'-I{p}' for p in include],*link,'-lavformat','-lavcodec','-lavutil','-lm','-o',args.output/name]
    run('compile-'+name,command)
run('config',[args.output/'config'])

def preflight(label, source, expected):
    value = json.loads(run(label,[args.output/'preflight',source]).stdout)
    assert value['mvc'] == expected, (label,value)
    if expected:
        assert value['width']==3840 and value['height']==1080, value
    assert 0 < value['header_bytes'] <= 8*1024*1024, value
    results.append(dict(case=label,**value))

preflight('local-header',args.media,True)
if args.ordinary:
    preflight('ordinary-header',args.ordinary,False)

# Mapping-only/legacy-only track declarations without making full movie copies.
prefix = args.media.open('rb').read(1024*1024)
map_marker = b'\x41\xe7\x84mvcC'
legacy_marker = b'\x00\x00\x01\xa8mvcC'
if prefix.count(map_marker)==1 and prefix.count(legacy_marker)==1:
    for label, old, new, expected in (
        ('legacy-only',map_marker,b'\x41\xe7\x84zzzz',True),
        ('mapping-only',legacy_marker,b'\x00\x00\x01\xa8zzzz',True)):
        fixture=args.output/(label+'.mkv')
        fixture.write_bytes(prefix.replace(old,new))
        preflight(label,fixture,expected)

def decode(label, source, seek=None, duration=None):
    command = [args.binary_dir/'ffmpeg','-nostdin','-v','verbose']
    if seek is not None: command += ['-ss',str(seek)]
    command += ['-i',source,'-map','0:v:0','-map','0:a:0']
    if duration is not None: command += ['-t',str(duration)]
    command += ['-f','null','-']
    value = run(label,command,timeout=300)
    log = value.stderr.decode(errors='replace')
    video = re.findall(r'Output stream #0:0 \(video\): (\d+) frames encoded',log)
    audio = re.findall(r'Output stream #0:1 \(audio\): \d+ frames encoded \((\d+) samples\)',log)
    assert video and audio, label
    frames,samples = int(video[-1]),int(audio[-1])
    assert frames>=50 and samples>=96000, (label,frames,samples)
    assert '3840x1080' in log and 'h264_mvc' in log, label
    assert not re.search(r'Error during demuxing|decode errors;|missing a matched|MVC decoder reset',log.replace('0 decode errors;','')),label
    results.append(dict(case=label,video_pairs=frames,audio_samples=samples))
    return frames

frames=decode('complete-decode',args.media)
if args.expected_pairs: assert frames==args.expected_pairs,(frames,args.expected_pairs)
value=run('seek-pixels',[args.output/'seek',args.media,'--matroska',0,30,10,50,0],timeout=300)
seeks=[json.loads(line) for line in value.stdout.splitlines()]
assert len(seeks)==5 and all(x['passed'] and x['mismatch']==0 and x['rejected']==[0,0] for x in seeks),seeks
results.append(dict(case='seek-pixels',results=seeks))

requests=[]
class Handler(BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    def log_message(self,*_): pass
    def do_HEAD(self): self.serve(False)
    def do_GET(self): self.serve(True)
    def serve(self,body):
        if self.path=='/stall':
            time.sleep(2)
            self.close_connection=True
            return
        size=args.media.stat().st_size
        linear=self.path=='/linear.mkv'
        value=self.headers.get('Range','')
        match=re.fullmatch(r'bytes=(\d+)-(\d*)',value) if not linear else None
        begin=int(match[1]) if match else 0
        end=min(size-1,int(match[2])) if match and match[2] else size-1
        if begin>=size:
            self.send_response(416);self.send_header('Content-Range',f'bytes */{size}');self.send_header('Content-Length','0');self.end_headers();return
        self.send_response(206 if match else 200)
        if not linear:self.send_header('Accept-Ranges','bytes')
        self.send_header('Content-Length',str(end-begin+1))
        if match:self.send_header('Content-Range',f'bytes {begin}-{end}/{size}')
        self.end_headers()
        record=dict(offset=begin,status=206 if match else 200,sent=0)
        requests.append(record)
        if not body:return
        try:
            with args.media.open('rb') as source:
                source.seek(begin);remaining=end-begin+1
                while remaining:
                    data=source.read(min(65536,remaining))
                    if not data:break
                    self.wfile.write(data);remaining-=len(data);record['sent']+=len(data)
        except (BrokenPipeError,ConnectionResetError):pass

server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
server.daemon_threads=True
thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
url=f'http://127.0.0.1:{server.server_port}/video.mkv'
try:
    preflight('http-header',url,True)
    linear=run('http-linear-preserved',[args.output/'preflight',url.replace('/video.mkv','/linear.mkv')])
    assert json.loads(linear.stdout)==dict(mvc=False,width=0,height=0,header_bytes=0)
    results.append(dict(case='linear-http-original-path',passed=True))
    decode('http-seek-audio',url,30,3)
    assert any(x['offset']>0 and x['status']==206 for x in requests),requests
    started=time.monotonic()
    stalled=run('stalled-deadline',[args.output/'preflight',url.replace('/video.mkv','/stall'),250],timeout=5,success=False)
    elapsed=time.monotonic()-started
    assert stalled.returncode and elapsed<2,(stalled.returncode,elapsed)
    results.append(dict(case='http-ranges',requests=requests,deadline_seconds=elapsed))
finally:
    server.shutdown();server.server_close();thread.join(timeout=3)
(args.output/'result.json').write_text(json.dumps(results,indent=2)+'\n')
print(json.dumps(results,indent=2),flush=True)
