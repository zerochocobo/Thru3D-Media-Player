"""Exercise the production Douyin adapter in anonymous desktop Firefox.

Reports contain booleans/counts and public content IDs. With --decode, the selected
private media message travels through authenticated loopback memory to the production
Kotlin probe and local FFmpeg; signed URLs and headers are never saved. This does not
establish Android output, logged-in content or live streams.
"""
import argparse
import base64
import hashlib
import http.server
import json
import pathlib
import re
import secrets
import socket
import subprocess
import threading
import time
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'android/web-browser/src/main/assets/web-browser'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--url', default='https://www.douyin.com/video/6961737553342991651')
    parser.add_argument('--firefox', type=pathlib.Path, default=ROOT / 'build/tools/firefox/firefox/firefox.exe')
    parser.add_argument('--geckodriver', type=pathlib.Path, default=ROOT / 'build/tools/firefox/geckodriver.exe')
    parser.add_argument('--inspect', action='store_true', help='One bounded initial checkpoint for diagnosis')
    parser.add_argument('--second-url', help='Explicit public second sample instead of the first visible recommendation')
    parser.add_argument('--decode', action='store_true', help='Require production Kotlin validation and complete local video/audio decoding')
    parser.add_argument('--host-runtime', type=pathlib.Path, default=ROOT / 'build/output/web-video-desktop-host/runtime.json')
    parser.add_argument('--single', action='store_true', help='Initial load, pause and reload only')
    parser.add_argument('--recommendations', type=int, choices=[0, 1, 2], default=0, help='Use real pointer clicks on visible video links')
    parser.add_argument('--pointer-delay', type=int, choices=range(0, 31), default=0, help='Wait before recommendation clicks to exercise delayed site prompts')
    args = parser.parse_args()
    if args.recommendations and (args.single or args.second_url): parser.error('Use pointer recommendations separately from --single/--second-url')
    if not re.fullmatch(r'https://www\.douyin\.com/video/[1-9][0-9]{14,19}/?', args.url):
        parser.error('Use a public HTTPS www.douyin.com video page')
    if args.second_url and not re.fullmatch(r'https://www\.douyin\.com/video/[1-9][0-9]{14,19}/?', args.second_url):
        parser.error('The second sample must also be a public HTTPS www.douyin.com video page')
    run = ROOT / 'build/output/douyin-desktop' / time.strftime('%Y%m%d-%H%M%S')
    ext = ROOT / 'tmp' / ('douyin-desktop-' + secrets.token_hex(6))
    profiles = ext.with_name(ext.name + '-profiles')
    ext.mkdir(parents=True); profiles.mkdir(); run.mkdir(parents=True)
    reports = []; commands = []; private = {}; memory_streams = {}; token = secrets.token_hex(24)

    class NoMediaRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *unused): return None
    media_opener = urllib.request.build_opener(NoMediaRedirect())

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *unused): pass
        def do_GET(self):
            stream_path = '/' + token + '/stream/'
            role = self.path[len(stream_path):] if self.path.startswith(stream_path) else ''
            if role in memory_streams:
                content = memory_streams[role]
                total = len(content); start, end = 0, total - 1
                requested = self.headers.get('Range')
                if requested:
                    match = re.fullmatch(r'bytes=([0-9]+)-([0-9]*)', requested)
                    if not match or int(match[1]) >= total:
                        self.send_response(416); self.send_header('Content-Range', f'bytes */{total}'); self.end_headers(); return
                    start = int(match[1]); end = min(int(match[2]) if match[2] else total - 1, total - 1)
                    if end < start:
                        self.send_response(416); self.end_headers(); return
                self.send_response(206 if requested else 200)
                self.send_header('Content-Type', 'video/mp4'); self.send_header('Accept-Ranges', 'bytes')
                self.send_header('Content-Length', str(end - start + 1))
                if requested: self.send_header('Content-Range', f'bytes {start}-{end}/{total}')
                self.end_headers()
                try: self.wfile.write(content[start:end+1])
                except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError): pass
                return
            command_path, _, query = self.path.partition('?')
            if command_path != '/' + token + '/command':
                self.send_error(404); return
            doc = urllib.parse.parse_qs(query).get('doc', [''])[0]
            payload = json.dumps(commands.pop(0) if commands and str(commands[0].get('doc')) == doc else {}).encode()
            self.send_response(200); self.send_header('Content-Type', 'application/json'); self.end_headers()
            try: self.wfile.write(payload)
            except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError): pass
        def do_POST(self):
            length = int(self.headers.get('Content-Length', '0'))
            if self.path == '/' + token + '/private' and args.decode and 0 < length <= 256 * 1024:
                data = json.loads(self.rfile.read(length)); item = data.get('media', {})
                content_id = item.get('douyin', {}).get('id')
                if isinstance(content_id, str) and re.fullmatch(r'[1-9][0-9]{14,19}', content_id):
                    private[(content_id, data.get('doc'))] = data
                    while len(private) > 8: private.pop(next(iter(private)))
                self.send_response(204); self.end_headers(); return
            if self.path != '/' + token or not 0 < length < 32768:
                self.send_error(400); return
            reports.append(json.loads(self.rfile.read(length)))
            (run / 'latest.json').write_text(json.dumps(reports[-1], indent=2), encoding='utf8')
            if len(reports) > 256: reports.pop(0)
            self.send_response(204); self.end_headers()

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    hashes = {}
    for name in ['bilibili.js', 'bilibili-response.js', 'douyin.js', 'douyin-response.js', 'network.js', 'media.js']:
        data = (SOURCE / name).read_bytes(); hashes[name] = hashlib.sha256(data).hexdigest()
        if name == 'media.js':
            old = b'browser.runtime.connectNative("thru3d_video")'; assert data.count(old) == 1
            data = data.replace(old, b'browser.runtime.connect({name:"desktop_douyin"})')
            diagnostic = r'''items.push({ douyin_diagnostics: (()=>{try{return douyinData.filter(d=>d.id===Thru3DDouyin.page(location.href)?.id).map(d=>({duration:d.duration,dimensions:d.video.map(t=>[t.width,t.height]),matches:d.video.map(t=>t.urls.some(u=>Thru3DDouyin.matches(u,currentSource))),paths:d.video.flatMap(t=>t.urls.filter(u=>new URL(u).pathname===new URL(currentSource).pathname).map(u=>{const a=new URL(u),b=new URL(currentSource);return {same_origin:a.origin===b.origin,added:[...b.searchParams.keys()].filter(k=>!a.searchParams.has(k)),changed:[...a.searchParams.keys()].filter(k=>a.searchParams.get(k)!==b.searchParams.get(k))};}))}));}catch(e){return e.name;}})(), id:'''
            diagnostic = diagnostic.replace('return e.name;', "return e.name+':'+e.message.replace(/https?:\\S+/g,'url');")
            diagnostic = diagnostic.replace('[...b.searchParams.keys()]', "b.search.slice(1).split('&').map(p=>decodeURIComponent(p.split('=')[0]))")
            diagnostic = diagnostic.replace('[...a.searchParams.keys()]', "a.search.slice(1).split('&').map(p=>decodeURIComponent(p.split('=')[0]))")
            diagnostic = diagnostic.replace('items.push({', "items.push({ douyin_probe_context: {enabled:douyinEnabled,page:Thru3DDouyin.page(location.href),ids:douyinData.map(d=>d.id),owner:douyinPrimary===video,scoped_files:requests.length,declared_request_offsets_ms:network.filter(r=>douyinData.some(d=>d.id===Thru3DDouyin.page(location.href)?.id&&d.video.some(t=>t.width===video.videoWidth&&t.height===video.videoHeight&&t.urls.some(u=>Thru3DDouyin.matches(u,r.url,d.id))))).map(r=>r.at-epoch.since),audio_tracks:douyinData.filter(d=>d.id===Thru3DDouyin.page(location.href)?.id).flatMap(d=>d.audio||[]).length,raw_audio_matches:network.filter(r=>douyinData.some(d=>d.id===Thru3DDouyin.page(location.href)?.id&&(d.audio||[]).some(t=>t.urls.some(u=>Thru3DDouyin.matches(u,r.url,d.id))))).length,file_relationships:network.filter(r=>r.kind==='file').slice(0,8).map(r=>{const b=new URL(r.url),tail=u=>u.pathname.split('/').filter(Boolean).slice(-2).join('/');const tracks=douyinData.filter(d=>d.id===Thru3DDouyin.page(location.href)?.id).flatMap(d=>[...d.video.map(t=>({...t,role:'video'})),...(d.audio||[]).map(t=>({...t,role:'audio'}))]);return tracks.flatMap(t=>t.urls.filter(x=>tail(new URL(x))===tail(b)).slice(0,2).map(x=>{const a=new URL(x),keys=u=>u.search.slice(1).split('&').filter(Boolean).map(p=>decodeURIComponent(p.split('=')[0]));return {role:t.role,same_origin:a.origin===b.origin,same_path:a.pathname===b.pathname,path_shapes:[a.pathname,b.pathname].map(p=>p.split('/').filter(Boolean).map(s=>({length:s.length,kind:['video','tos','cn'].includes(s)?s:s.startsWith('tos-cn-')?'bucket':/^[a-fA-F0-9]+$/.test(s)?'hex':/^[A-Za-z0-9_-]+$/.test(s)?'key':'other'}))),changed:keys(a).filter(k=>a.searchParams.get(k)!==b.searchParams.get(k)),added:keys(b).filter(k=>!a.searchParams.has(k))};})).slice(0,3);}),raw_files:network.filter(r=>r.kind==='file').length,raw_id_matches:network.filter(r=>Thru3DDouyin.sourceId(r.url)===Thru3DDouyin.page(location.href)?.id).length,raw_video_matches:network.filter(r=>douyinData.some(d=>d.id===Thru3DDouyin.page(location.href)?.id&&d.video.some(t=>t.width===video.videoWidth&&t.height===video.videoHeight&&t.urls.some(u=>Thru3DDouyin.matches(u,r.url,d.id))))).length},")
            data = data.replace(b'items.push({ id:', diagnostic.encode())
        (ext / name).write_bytes(data)
    bridge = r'''
let sequence=0;const apiRequests=[],mediaEvents=[];
browser.webRequest.onHeadersReceived.addListener(d=>{const mime=(d.responseHeaders||[]).find(h=>h.name.toLowerCase()==='content-type')?.value||'';if(!/^(video|audio)\//i.test(mime)&&d.type!=='media')return;mediaEvents.push({mime:mime.split(';')[0],status:d.statusCode,frame:d.frameId,type:d.type,cached:!!d.fromCache});if(mediaEvents.length>24)mediaEvents.shift();},{urls:['https://*/*']},['responseHeaders']);
browser.webRequest.onErrorOccurred.addListener(d=>{if(d.type!=='media'&&!new URL(d.url).hostname.endsWith('.douyinvod.com'))return;mediaEvents.push({error:(d.error||'').slice(0,80),frame:d.frameId,type:d.type});if(mediaEvents.length>24)mediaEvents.shift();},{urls:['https://*/*']});
browser.webRequest.onBeforeRequest.addListener(d=>{const page=v=>{try{return new URL(v).origin+new URL(v).pathname}catch(_){return ''}};apiRequests.push({api:new URL(d.url).pathname,method:d.method,tab:d.tabId,frame:d.frameId,document:page(d.documentUrl),origin:page(d.originUrl),document_id:!!d.documentId});if(apiRequests.length>12)apiRequests.shift();},{urls:['https://www.douyin.com/aweme/v1/web/aweme/*'],types:['xmlhttprequest']});
browser.runtime.onMessage.addListener(message=>{if(message?.probe_error)fetch('ENDPOINT',{method:'POST',body:JSON.stringify(message)}).catch(()=>{});});
browser.runtime.onConnect.addListener(port=>{
 if(port.name!=='desktop_douyin')return;const doc=++sequence;
 port.postMessage({action:'network_policy',enabled:false,bilibili:false,douyin:true,diagnostics:true});
 const poll=setInterval(()=>fetch('ENDPOINT/command?doc='+doc).then(r=>r.json()).then(c=>{if(c.action)port.postMessage(c)}).catch(()=>{}),250);
 port.onDisconnect.addListener(()=>clearInterval(poll));
 port.onMessage.addListener(message=>{
  if(!Array.isArray(message.videos))return;
  const selected=message.videos.find(v=>v.douyin_ready);
  if(selected&&DECODE)fetch('ENDPOINT/private',{method:'POST',body:JSON.stringify({doc,media:{...selected,douyin_enabled:true}})}).catch(()=>{});
  const videos=message.videos.map(v=>({width:v.width,height:v.height,duration:v.duration,time:v.time,playing:v.playing,
    ready:v.douyin_ready,metadata:!!v.douyin,id:v.douyin?.id,requests:v.network?.length||0,counts:v.douyin_diagnostics,context:v.douyin_probe_context}));
  const shape=globalThis.douyinShapes||{},currentId=Thru3DDouyin.page(message.videos[0]?.frame)?.id;
  fetch('ENDPOINT',{method:'POST',body:JSON.stringify({doc,page_id:currentId,videos,pause_token:message.pause_token,pause_held:message.pause_held,pause_has_media:message.pause_has_media,api_requests:apiRequests,media_events:mediaEvents,diagnostics:{normalized:shape.normalized,binding:shape.binding,current:shape.models?.[currentId]}})}).catch(()=>{});
 });
});
'''.replace('ENDPOINT', f'http://127.0.0.1:{server.server_port}/{token}').replace('DECODE', 'true' if args.decode else 'false')
    (ext / 'bridge.js').write_text(bridge, encoding='utf8')
    (ext / 'shape.js').write_text(r'''
globalThis.douyinShapes={normalized:[],binding:[],models:Object.create(null)};
addEventListener('error',event=>{try{browser.runtime.sendMessage({probe_error:true,message:(event.message||'').replace(/https?:\S+/g,'url').slice(0,200),stack:(event.error?.stack||'').split('\n').slice(0,3).map(s=>s.replace(/@.*/,''))});}catch(_){} });
const originalNormalize=Thru3DDouyin.normalize,originalBinding=Thru3DDouyin.binding;
const modelShape=(v,depth=0)=>depth>6?typeof v:Array.isArray(v)?{length:v.length,items:v.slice(0,1).map(x=>modelShape(x,depth+1))}:v&&typeof v==='object'?Object.fromEntries(Object.entries(v).slice(0,60).map(([k,x])=>[k,modelShape(x,depth+1)])):typeof v;
Thru3DDouyin.normalize=raw=>{const data=originalNormalize(raw);let model;try{model=JSON.parse(raw.video?.video_model||'null')}catch(_){}douyinShapes.models[raw.aweme_id]={id:raw.aweme_id,accepted:!!data,duration:data?.duration,protocols:[raw.video?.play_addr,...(raw.video?.bit_rate||[]).map(t=>t.play_addr)].filter(Boolean).map(t=>(t.url_list||[]).map(u=>u.split(':')[0])),video_keys:Object.keys(raw.video||{}),model:modelShape(model),audio:modelShape(raw.video?.bit_rate_audio),ads:!!raw.is_ads,images:raw.images?.length,preview:!!raw.is_preview,encrypted:!!raw.video?.is_encrypted};while(Object.keys(douyinShapes.models).length>24)delete douyinShapes.models[Object.keys(douyinShapes.models)[0]];douyinShapes.normalized.push({accepted:!!data,duration:data?.duration,dimensions:data?.video.map(t=>[t.width,t.height])});if(douyinShapes.normalized.length>8)douyinShapes.normalized.shift();return data;};
Thru3DDouyin.binding=(data,value,video,requests)=>{const result=originalBinding(data,value,video,requests);if(data?.id===Thru3DDouyin.page(value)?.id&&video.videoWidth>0){douyinShapes.binding=[{dimensions:data?.video.map(t=>[t.width,t.height]),address:data?.video.some(t=>t.urls.some(u=>Thru3DDouyin.matches(u,video.currentSrc))),duration_delta:Math.abs(data?.duration-video.duration),requests:requests.length,matched:!!result,paths:data.video.flatMap(t=>t.urls.filter(u=>new URL(u).pathname===new URL(video.currentSrc).pathname).map(u=>{const a=new URL(u),b=new URL(video.currentSrc);return {same_origin:a.origin===b.origin,added:[...b.searchParams.keys()].filter(k=>!a.searchParams.has(k)),changed:[...a.searchParams.keys()].filter(k=>a.searchParams.get(k)!==b.searchParams.get(k))};}))}];}return result;};
''', encoding='utf8')
    (ext / 'manifest.json').write_text(json.dumps({'manifest_version': 2, 'name': 'Douyin production capture test', 'version': '1.0',
        'permissions': ['webRequest', 'webRequestBlocking', 'cookies', 'https://*/*', 'http://127.0.0.1/*'],
        'background': {'scripts': ['bridge.js', 'bilibili.js', 'bilibili-response.js', 'douyin.js', 'shape.js', 'douyin-response.js', 'network.js']},
        'content_scripts': [{'matches': ['https://www.douyin.com/*'], 'js': ['bilibili.js', 'douyin.js', 'media.js'], 'run_at': 'document_start'}]}))
    with socket.socket() as probe: probe.bind(('127.0.0.1', 0)); port = probe.getsockname()[1]
    driver = subprocess.Popen([str(args.geckodriver), '--allow-system-access', '--profile-root', str(profiles), '--port', str(port), '--log', 'fatal'], stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL, creationflags=subprocess.CREATE_NO_WINDOW if hasattr(subprocess, 'CREATE_NO_WINDOW') else 0)
    session = None

    def call(method, path, data=None):
        req = urllib.request.Request(f'http://127.0.0.1:{port}' + path, data=json.dumps(data).encode() if data is not None else None,
            headers={'Content-Type': 'application/json'}, method=method)
        with urllib.request.urlopen(req, timeout=65) as response: return json.load(response)['value']
    def cmd(path, data=None): return call('POST', '/session/' + session + path, data)
    def script(code, args=None): return cmd('/execute/sync', {'script': code, 'args': args or []})
    def pointer_click(target, name):
        cmd('/actions', {'actions': [{'type': 'pointer', 'id': name, 'parameters': {'pointerType': 'mouse'}, 'actions': [
            {'type': 'pointerMove', 'duration': 100, 'x': target['x'], 'y': target['y']},
            {'type': 'pointerDown', 'button': 0}, {'type': 'pointerUp', 'button': 0}]}]})
    stages = []
    initial_id = args.url.rstrip('/').rsplit('/', 1)[1]
    def decode_current(latest):
        item = next((v for v in (latest or {}).get('videos', []) if v.get('ready')), None)
        if not item: return {'passed': False, 'error': 'not_ready'}
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            saved = private.get((item['id'], latest.get('doc')))
            if saved and saved.get('doc') == latest.get('doc'): break
            time.sleep(.05)
        else: return {'passed': False, 'error': 'private_snapshot_missing'}
        media = saved['media']; result = {'passed': False}
        if not 0 < media.get('duration', 0) <= 120: return {'passed': False, 'error': 'sample_duration_budget'}
        try:
            runtime = json.loads(args.host_runtime.read_text(encoding='utf-8-sig'))
            if not runtime.get('source_sha256') or any(hashlib.sha256((ROOT / p).read_bytes()).hexdigest() != value for p, value in runtime['source_sha256'].items()):
                raise ValueError('host_runtime_stale')
            native = subprocess.run([runtime['java'], '-Djava.net.useSystemProxies=true', '-cp', runtime['classpath'], runtime['main']],
                input=json.dumps(media).encode(), capture_output=True, timeout=40)
            result['native'] = json.loads(native.stdout)
            if native.returncode or not result['native'].get('passed'): return result
            source = media['douyin'].get('observed_file') if media.get('blob') else media['source']
            sources = {'video': source}
            if media['douyin'].get('observed_audio'): sources['audio'] = media['douyin']['observed_audio']
            total = 0; result['streams'] = []; probes_ok = True
            for role, address in sources.items():
                request = next(r for r in media['network'] if r['url'] == address and r['kind'] == 'file')
                remote = urllib.request.Request(request['url'], headers=request['headers'])
                with media_opener.open(remote, timeout=30) as response:
                    parts = []; deadline = time.monotonic() + 45
                    while True:
                        if time.monotonic() > deadline: raise TimeoutError('sample_read_budget')
                        chunk = response.read(min(65536, 64 * 1024 * 1024 + 1 - total))
                        if not chunk: break
                        total += len(chunk); parts.append(chunk)
                        if total > 64 * 1024 * 1024: raise ValueError('sample_too_large')
                    content = b''.join(parts); memory_streams[role] = content
                    if response.status == 206:
                        value = re.fullmatch(r'bytes 0-([0-9]+)/([0-9]+)', response.headers.get('Content-Range', ''))
                        if not value or int(value[1]) + 1 != len(content) or int(value[2]) != len(content): raise ValueError('partial_sample')
                    elif response.headers.get('Content-Length') and int(response.headers['Content-Length']) != len(content): raise ValueError('truncated_sample')
                local = f'http://127.0.0.1:{server.server_port}/{token}/stream/{role}'
                probe = subprocess.run(['ffprobe', '-v', 'error', '-show_streams', '-of', 'json', local], capture_output=True, timeout=25)
                probes_ok = probes_ok and probe.returncode == 0
                streams = json.loads(probe.stdout).get('streams', [])
                result['streams'].extend({'resource': role, **{k: s[k] for k in ['codec_type', 'codec_name', 'width', 'height', 'duration', 'sample_rate', 'channels', 'start_time', 'time_base'] if k in s}} for s in streams)
            local_video = f'http://127.0.0.1:{server.server_port}/{token}/stream/video'
            local_audio = f'http://127.0.0.1:{server.server_port}/{token}/stream/' + ('audio' if 'audio' in sources else 'video')
            joint = ['ffmpeg', '-v', 'error', '-i', local_video]
            if 'audio' in sources: joint += ['-i', local_audio]
            joint += ['-map', '0:v:0', '-map', ('1' if 'audio' in sources else '0') + ':a:0', '-progress', 'pipe:1', '-f', 'null', '-']
            video = subprocess.run(joint, capture_output=True, timeout=45)
            progress = dict(line.split('=', 1) for line in video.stdout.decode().splitlines() if '=' in line)
            audio = subprocess.run(['ffmpeg', '-v', 'error', '-i', local_audio, '-map', '0:a:0', '-vn', '-ac', '2', '-ar', '48000', '-f', 's16le', 'pipe:1'], capture_output=True, timeout=45)
            result.update({'bytes': total, 'video_exit': video.returncode, 'audio_exit': audio.returncode,
                'video_frames': int(progress.get('frame', 0)), 'video_time_us': int(progress.get('out_time_us', 0)),
                'audio_samples_48k_stereo': len(audio.stdout) // 4, 'audio_nonzero': any(audio.stdout)})
            duration = media['duration']
            fresh = private.get((item['id'], latest.get('doc')), {}).get('media', {})
            identity = lambda m: (m.get('id'), m.get('frame'), m.get('network_epoch'), m.get('source'),
                m.get('douyin', {}).get('observed_file'), m.get('douyin', {}).get('observed_audio'))
            result['fresh_binding'] = identity(fresh) == identity(media) and bool(reports) and reports[-1].get('doc') == latest.get('doc') and reports[-1].get('page_id') == item['id']
            result['passed'] = result['fresh_binding'] and result['audio_nonzero'] and video.returncode == audio.returncode == 0 and probes_ok and result['video_frames'] >= 8 and result['video_time_us'] >= (duration - .5) * 1e6 and result['audio_samples_48k_stereo'] >= (duration - .5) * 48000
        except Exception as error: result['error_type'] = type(error).__name__
        finally: memory_streams.clear()
        return result
    def checkpoint(name, expected_id=None, after_doc=0):
        end = time.monotonic() + 25
        latest = None
        while time.monotonic() < end:
            choices = [r for r in reports if r.get('page_id') == expected_id and r.get('doc', 0) > after_doc]
            latest = choices[-1] if choices else None
            if latest and any(v.get('ready') and v.get('id') == expected_id for v in latest.get('videos', [])): break
            time.sleep(.25)
        stages.append({'name': name, 'expected_id': expected_id, 'latest': latest,
            'dom': script("return {page:location.origin+location.pathname+location.search,ready:document.readyState,videos:[...document.querySelectorAll('video')].map(v=>({width:v.videoWidth,height:v.videoHeight,duration:v.duration,paused:v.paused,seeking:v.seeking,ready_state:v.readyState,network_state:v.networkState,error_code:v.error?.code,buffered_ranges:v.buffered.length,source:(v.currentSrc||'').split(':')[0],resource_id:(v.currentSrc||'').startsWith('https:')?new URL(v.currentSrc).searchParams.get('__vid'):null}))};")})
        if args.decode: stages[-1]['decode'] = decode_current(stages[-1]['latest'])
        (run / 'stages.json').write_text(json.dumps(stages, indent=2), encoding='utf8')
    def inspect_controls():
        controls = script("return [...document.querySelectorAll('button,[role=button],[aria-label],[class*=close]')].filter(e=>{const r=e.getBoundingClientRect();return r.width>0&&r.height>0&&r.top>=0&&r.bottom<=innerHeight}).slice(0,100).map(e=>({tag:e.tagName,classes:typeof e.className==='string'?e.className.slice(0,140):'',label:e.getAttribute('aria-label'),e2e:e.getAttribute('data-e2e'),text:e.textContent.trim().slice(0,35)}));")
        (run / 'controls.json').write_text(json.dumps(controls, ensure_ascii=False, indent=2), encoding='utf8')
        (run / 'page.png').write_bytes(base64.b64decode(call('GET', '/session/' + session + '/screenshot')))
    try:
        for _ in range(100):
            try: call('GET', '/status'); break
            except Exception: time.sleep(.1)
        value = call('POST', '/session', {'capabilities': {'alwaysMatch': {'browserName': 'firefox', 'pageLoadStrategy': 'eager',
            'moz:firefoxOptions': {'binary': str(args.firefox), 'args': ['-headless'],
                'prefs': {'media.autoplay.default': 0, 'media.autoplay.blocking_policy': 0}}}}})
        session = value['sessionId']; cmd('/moz/addon/install', {'path': str(ext), 'temporary': True})
        (ext / 'session.json').write_text(json.dumps({'port': port, 'session': session}), encoding='utf8')
        cmd('/window/rect', {'width': 1500, 'height': 1000}); cmd('/url', {'url': args.url})
        checkpoint('initial', initial_id)
        if args.inspect:
            inspect_controls()
            render = script("const raw=JSON.parse(decodeURIComponent(document.getElementById('RENDER_DATA')?.textContent||'%7B%7D'));const found=[];let count=0;function shape(v,n=0){if(n>4)return typeof v;if(Array.isArray(v))return {length:v.length,items:v.slice(0,2).map(x=>shape(x,n+1))};if(v&&typeof v==='object')return Object.fromEntries(Object.entries(v).map(([k,x])=>[k,shape(x,n+1)]));return typeof v==='string'?(v.startsWith('http')?'url':v.length>80?'text':v):v;}function walk(v){if(!v||typeof v!=='object'||++count>10000)return;if(v.video&&(v.awemeId||v.aweme_id))found.push({id:v.awemeId||v.aweme_id,keys:Object.keys(v),video:shape(v.video)});for(const x of Object.values(v))walk(x);}walk(raw);return {root:Object.keys(raw),found:found.slice(0,3)};")
            (run / 'render-shape.json').write_text(json.dumps(render, indent=2), encoding='utf8')
            structure = script("const raw=JSON.parse(decodeURIComponent(document.getElementById('RENDER_DATA')?.textContent||'%7B%7D'));const out=[];let n=0;function walk(v,path){if(!v||typeof v!=='object'||++n>10000||out.length>50)return;const keys=Object.keys(v);if(keys.some(k=>/aweme|video|play.?addr/i.test(k)))out.push({path,keys,children:Object.fromEntries(keys.filter(k=>/aweme|video|play.?addr/i.test(k)).map(k=>[k,typeof v[k]==='object'?Object.keys(v[k]||{}):typeof v[k]]))});for(const k of keys)walk(v[k],path+'.'+k);}walk(raw,'root');return out;")
            (run / 'render-structure.json').write_text(json.dumps(structure, indent=2), encoding='utf8')
            cmd('/moz/context', {'context': 'chrome'})
            errors = script("return Services.console.getMessageArray().filter(e=>/moz-extension:/.test(e.sourceName||'')).map(e=>({message:e.errorMessage?.slice(0,200),source:e.sourceName?.split('/').pop(),line:e.lineNumber}));")
            (run / 'errors.json').write_text(json.dumps(errors, indent=2), encoding='utf8')
            cmd('/moz/context', {'context': 'content'})
            print(json.dumps(stages)); print('Report:', run / 'stages.json'); return
        initial_doc = (stages[-1]['latest'] or {}).get('doc')
        if not initial_doc: raise RuntimeError('Website did not load current playable media')
        commands.append({'doc': initial_doc, 'action': 'pause_media', 'token': 1, 'playing_ids': []})
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            if any(r.get('doc') == initial_doc and r.get('pause_token') == 1 and r.get('pause_held') for r in reports[-12:]): break
            time.sleep(.1)
        else: raise RuntimeError('Production content port did not acknowledge its pause lease')
        checkpoint('paused', initial_id)
        commands.append({'doc': initial_doc, 'action': 'release_pause_media', 'token': 1, 'play': False})
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if reports[-1].get('doc') == initial_doc and reports[-1].get('pause_token') == 0 and not reports[-1].get('pause_held'): break
            time.sleep(.1)
        else: raise RuntimeError('Production content port did not release its pause lease')
        stages[-1]['pause_released'] = True
        script("document.querySelector('video')?.play().catch(()=>{});return true;")
        target = None if args.single else script("const a=[...document.querySelectorAll('a[href*=\"/video/\"]')].find(a=>new URL(a.href).origin===location.origin&&/^\\/video\\/[1-9][0-9]{14,19}$/.test(new URL(a.href).pathname)&&new URL(a.href).pathname!==location.pathname&&a.getBoundingClientRect().width>0);if(!a)return null;a.scrollIntoView({block:'center'});const r=a.getBoundingClientRect();return {id:new URL(a.href).pathname.split('/')[2],x:Math.round(r.x+r.width/2),y:Math.round(r.y+r.height/2)};")
        if args.second_url: target = {'id': args.second_url.split('/video/', 1)[1].split('/', 1)[0].split('?', 1)[0]}
        if args.single: target = None
        reload_id = initial_id
        if args.recommendations:
            time.sleep(args.pointer_delay)
            for index in range(args.recommendations):
                dismissed_prompt = False
                target = script("const a=[...document.querySelectorAll('a[href*=\"/video/\"]')].find(a=>new URL(a.href).origin===location.origin&&/^\\/video\\/[1-9][0-9]{14,19}$/.test(new URL(a.href).pathname)&&new URL(a.href).pathname!==location.pathname&&a.getBoundingClientRect().width>=60&&a.getBoundingClientRect().height>=30);if(!a)return null;a.scrollIntoView({block:'center'});const r=a.getBoundingClientRect(),x=Math.round(r.x+r.width/2),y=Math.round(r.y+r.height/2),top=document.elementFromPoint(x,y);return {id:new URL(a.href).pathname.split('/')[2],x,y,clickable:top===a||a.contains(top),target:a.target};")
                if target and not target['clickable']:
                    # A real Escape key may dismiss the site's anonymous login prompt.
                    # Never remove an overlay or synthesize the link's DOM click.
                    cmd('/actions', {'actions': [{'type': 'key', 'id': 'dismiss', 'actions': [
                        {'type': 'keyDown', 'value': '\ue00c'}, {'type': 'keyUp', 'value': '\ue00c'}]}]})
                    time.sleep(.5)
                    target['clickable'] = script('const e=document.elementFromPoint(arguments[0],arguments[1]);return !!e?.closest("a[href]")&&new URL(e.closest("a[href]").href).pathname==="/video/"+arguments[2];', [target['x'], target['y'], target['id']])
                    if not target['clickable']:
                        # Selector observed from the site's visible close control.
                        close = script("const e=document.querySelector('#douyin_login_comp_flat_panel .YoNA2Hyj.qKr0RhiL');if(!e)return null;const r=e.getBoundingClientRect(),x=Math.round(r.x+r.width/2),y=Math.round(r.y+r.height/2);return r.width>0&&r.width<=50&&r.height>0&&r.height<=50&&e.contains(document.elementFromPoint(x,y))?{x,y}:null;")
                        if close:
                            pointer_click(close, 'close-login-prompt'); time.sleep(.5)
                            dismissed_prompt = script("const e=document.querySelector('#douyin_login_comp_flat_panel');return !e||!e.getBoundingClientRect().width;")
                            target['clickable'] = script('const e=document.elementFromPoint(arguments[0],arguments[1]);return !!e?.closest("a[href]")&&new URL(e.closest("a[href]").href).pathname==="/video/"+arguments[2];', [target['x'], target['y'], target['id']])
                if not target or not target['clickable']:
                    inspect_controls(); stages.append({'name': 'recommendation_' + str(index+1), 'expected_id': None, 'latest': None, 'error': 'no_visible_link' if not target else 'link_obstructed'}); break
                before_origin = script('return performance.timeOrigin;')
                handles = set(call('GET', '/session/' + session + '/window/handles'))
                previous_doc = (stages[-1]['latest'] or {}).get('doc', 0)
                pointer_click(target, 'recommendation')
                time.sleep(.5)
                added = set(call('GET', '/session/' + session + '/window/handles')) - handles
                if added: cmd('/window', {'handle': next(iter(added))})
                checkpoint('recommendation_' + str(index+1), target['id'])
                reload_id = target['id']
                stages[-1]['same_document'] = script('return performance.timeOrigin;') == before_origin
                stages[-1]['previous_doc'] = previous_doc
                stages[-1]['login_prompt_dismissed'] = dismissed_prompt
        elif target:
            reports.clear()
            # Address navigation tests a second real public video without relying on
            # recommendation cards obscured by the site's anonymous-login overlay.
            # This is intentionally not presented as a pointer/SPA acceptance test.
            cmd('/url', {'url': 'https://www.douyin.com/video/' + target['id']})
            checkpoint('second_video', target['id'])
            reload_id = target['id']
        previous_doc = (stages[-1].get('latest') or {}).get('doc', 0)
        reports.clear(); cmd('/refresh', {}); checkpoint('reload', reload_id, previous_doc)
        passed = all(s['latest'] and any(v.get('ready') and (s['expected_id'] is None or v.get('id') == s['expected_id']) for v in s['latest'].get('videos', [])) and (not args.decode or s.get('decode', {}).get('passed')) for s in stages)
        evidence = {'scope': 'anonymous desktop capture' + (' + production Kotlin + FFmpeg' if args.decode else '') + '; not Android acceptance', 'source_sha256': hashes,
            'native_source_sha256': json.loads(args.host_runtime.read_text(encoding='utf-8-sig')).get('source_sha256') if args.decode else None,
            'browser_version': value['capabilities']['browserVersion'], 'passed': passed, 'stages': stages, 'second_page_navigated': bool(target)}
        (run / 'summary.json').write_text(json.dumps(evidence, indent=2), encoding='utf8')
        print(json.dumps({'passed': passed, 'browser_version': evidence['browser_version'],
            'stages': [{'name': s['name'], 'expected_id': s['expected_id'],
                'ready': any(v.get('ready') for v in (s['latest'] or {}).get('videos', [])),
                'decode': s.get('decode'),
                'pause_held': (s['latest'] or {}).get('pause_held')} for s in stages]}))
        print('Report:', run / 'summary.json')
        if not passed: raise SystemExit(1)
    finally:
        if session:
            try: call('DELETE', '/session/' + session)
            except Exception: pass
        driver.terminate(); driver.wait(timeout=10); private.clear(); memory_streams.clear(); server.shutdown()


if __name__ == '__main__': main()
