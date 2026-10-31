"""Run production capture scripts in isolated desktop Firefox. No account import.

Firefox/geckodriver are explicit paths; output contains numeric/enum diagnostics only.
This is a desktop parser test, not Android playback or release acceptance.
"""
import argparse
import hashlib
import http.server
import json
import pathlib
import re
import secrets
import shutil
import socket
import subprocess
import threading
import time
import urllib.request
import urllib.parse

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'android/web-browser/src/main/assets/web-browser'

def extension(target, endpoint):
    target.mkdir(parents=True, exist_ok=True)
    hashes = {}
    for name in ['bilibili.js', 'bilibili-response.js', 'network.js', 'media.js']:
        data = (SOURCE / name).read_bytes()
        hashes[name] = hashlib.sha256(data).hexdigest()
        if name == 'media.js':
            old = b'browser.runtime.connectNative("thru3d_video")'
            assert data.count(old) == 1
            data = data.replace(old, b'browser.runtime.connect({name: "thru3d_desktop_media"})')
        (target / name).write_bytes(data)
    bridge = (ROOT / 'tools/web-video-desktop/bridge.js').read_text(encoding='utf8')
    (target / 'bridge.js').write_text(bridge.replace('__REPORT_ENDPOINT__', endpoint), encoding='utf8')
    shutil.copyfile(ROOT / 'tools/web-video-desktop/shape.js', target / 'shape.js')
    manifest = {'manifest_version': 2, 'name': 'Thru3D desktop capture test', 'version': '1.0',
                'browser_specific_settings': {'gecko': {'id': 'capture-test@thru3d.local'}},
                'permissions': ['webRequest', 'webRequestBlocking', 'cookies', 'https://*/*', 'http://127.0.0.1/*'],
                'background': {'scripts': ['bridge.js', 'bilibili.js', 'bilibili-response.js', 'network.js', 'shape.js']},
                'content_scripts': [{'matches': ['https://www.bilibili.com/video/*', 'https://www.bilibili.com/bangumi/play/*'],
                                     'js': ['bilibili.js', 'media.js'], 'run_at': 'document_start'}]}
    (target / 'manifest.json').write_text(json.dumps(manifest), encoding='utf8')
    return hashes

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--firefox', type=pathlib.Path, required=True)
    parser.add_argument('--geckodriver', type=pathlib.Path, required=True)
    parser.add_argument('--url', default='https://www.bilibili.com/video/BV1bK411W797/')
    parser.add_argument('--seconds', type=int, default=12)
    parser.add_argument('--inspect-pgc', action='store_true', help='Collect public DOM/endpoint shapes; this is not a playback pass')
    parser.add_argument('--single', action='store_true', help='Test first load and reload without selecting a second part')
    parser.add_argument('--recommendations', type=int, choices=[0, 1, 2], default=0, help='Click visible sidebar recommendations without reloading')
    args = parser.parse_args()
    parsed = urllib.parse.urlparse(args.url)
    if parsed.scheme != 'https' or parsed.netloc != 'www.bilibili.com' or not re.fullmatch(r'/(?:video/(BV[A-Za-z0-9]+|av[0-9]+)|bangumi/play/(?:ss|ep)[1-9][0-9]*)/?', parsed.path):
        parser.error('Use an HTTPS www.bilibili.com video or episode URL')
    if not 1 <= args.seconds <= 60: parser.error('--seconds must be 1..60')
    run = ROOT / 'build/output/bilibili-desktop' / time.strftime('%Y%m%d-%H%M%S')
    run.mkdir(parents=True)
    reports = []; token = secrets.token_hex(24)
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *unused): pass
        def do_POST(self):
            length = int(self.headers.get('Content-Length', '0'))
            if self.path != '/' + token or not 0 < length < 32768:
                self.send_error(400); return
            body = json.loads(self.rfile.read(length))
            reports.append(body)
            if len(reports) > 256: reports.pop(0)
            self.send_response(204); self.end_headers()
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    hashes = extension(run / 'extension', f'http://127.0.0.1:{server.server_port}/{token}')
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0)); port = probe.getsockname()[1]
    driver = subprocess.Popen([str(args.geckodriver.resolve()), '--host', '127.0.0.1', '--port', str(port), '--log', 'fatal'],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                              creationflags=subprocess.CREATE_NO_WINDOW if hasattr(subprocess, 'CREATE_NO_WINDOW') else 0)
    session = None
    def call(method, path, data=None):
        req = urllib.request.Request(f'http://127.0.0.1:{port}' + path,
                                     data=json.dumps(data).encode() if data is not None else None,
                                     headers={'Content-Type': 'application/json'}, method=method)
        with urllib.request.urlopen(req, timeout=70) as response: return json.load(response)['value']
    def command(path, data=None): return call('POST', '/session/' + session + path, data)
    def script(source): return command('/execute/sync', {'script': source, 'args': []})
    evidence = {'source_sha256': hashes, 'scope': 'anonymous desktop Firefox; no Android acceptance', 'stages': []}
    def checkpoint(name, part, expected_path=None):
        started = time.monotonic()
        while time.monotonic() - started < max(20, args.seconds):
            if reports and (expected_path is None or reports[-1].get('page_path') == expected_path) and reports[-1].get('part') == part and reports[-1].get('captured_video', 0) > 0 and reports[-1].get('captured_audio', 0) > 0:
                break
            time.sleep(.25)
        evidence['stages'].append({'name': name, 'wait_seconds': round(time.monotonic() - started, 2),
                                   'latest': reports[-1] if reports else None})
    try:
        for _ in range(100):
            try: call('GET', '/status'); break
            except Exception: time.sleep(.1)
        value = call('POST', '/session', {'capabilities': {'alwaysMatch': {'browserName': 'firefox',
            'moz:firefoxOptions': {'binary': str(args.firefox.resolve()), 'args': ['-headless'],
                'prefs': {'media.autoplay.default': 0, 'media.autoplay.blocking_policy': 0}}}}})
        session = value['sessionId']; evidence['browser_version'] = value['capabilities']['browserVersion']
        command('/moz/addon/install', {'path': str((run / 'extension').resolve()), 'temporary': True})
        command('/window/rect', {'width': 1500, 'height': 1100})
        command('/url', {'url': args.url})
        time.sleep(args.seconds)
        script("document.querySelector('video')?.play().catch(()=>{}); return true;")
        time.sleep(3)
        checkpoint('initial', int(urllib.parse.parse_qs(parsed.query).get('p', ['1'])[0]))
        # Public DOM inventory lets subsequent probes use observed elements, not guessed controls.
        evidence['parts'] = script("return [...document.querySelectorAll('a[href*=\"?p=\"]')].slice(0,25).map(a=>({text:a.textContent.trim().slice(0,60),part:new URL(a.href).searchParams.get('p')}));")
        evidence['part_controls'] = script("return [...document.querySelectorAll('[class*=pod], [class*=episode]')].filter(e=>e.textContent.trim().length<100).slice(0,40).map(e=>({tag:e.tagName,cls:e.className,text:e.textContent.trim().slice(0,80)}));")
        if args.inspect_pgc:
            evidence['pgc_dom'] = script("return [...document.querySelectorAll('a[href*=\"/bangumi/play/ep\"], [class*=numberList], [class*=epList], [class*=Episode]')].filter(e=>e.textContent.trim().length<90).slice(0,80).map(e=>({tag:e.tagName,cls:e.className,text:e.textContent.trim().slice(0,60),ep:/\\/ep(\\d+)/.exec(e.getAttribute('href')||'')?.[1],attrs:[...e.attributes].map(a=>a.name)}));")
            evidence['pgc_scripts'] = script("return [...document.scripts].filter(s=>!s.src&&/playurlSSRData/.test(s.textContent)).map(s=>({length:s.textContent.length,assignment:/(?:window\\.|(?:const|let|var)\\s+)playurlSSRData\\s*=/.test(s.textContent),raw:/\"raw\":/.test(s.textContent)}));")
            clicked_pgc = script("const a=[...document.querySelectorAll('button[class*=PlayerEpisodePanel_episodeRow__]')].find(e=>!e.className.includes('episodeRowActive')); if(a)a.click();return !!a;")
            if clicked_pgc:
                time.sleep(6); checkpoint('pgc_selected', 1)
        clicked = False if args.single or args.recommendations else script("const a=[...document.querySelectorAll('a[href*=\"?p=\"]')].find(a=>new URL(a.href).searchParams.get('p')==='2') || document.querySelectorAll('.video-pod__item')[1]; if(a){a.click();return true} return false;")
        if args.recommendations:
            for index in range(args.recommendations):
                reports.clear()
                target = script("const a=[...document.querySelectorAll('a.video-awesome-img')].find(a=>a.getBoundingClientRect().width>0&&new URL(a.href).pathname!==location.pathname); if(!a)return null; a.scrollIntoView({block:'center'});const r=a.getBoundingClientRect();return {path:new URL(a.href).pathname,x:Math.round(r.x+r.width/2),y:Math.round(r.y+r.height/2)};")
                if not target: break
                command('/actions', {'actions':[{'type':'pointer','id':'sidebar','parameters':{'pointerType':'mouse'},'actions':[
                    {'type':'pointerMove','duration':100,'x':target['x'],'y':target['y']}, {'type':'pointerDown','button':0}, {'type':'pointerUp','button':0}]}]})
                checkpoint('recommendation_' + str(index + 1), 1, target['path'])
        elif clicked:
            checkpoint('part_two', 2)
            reports.clear()
            command('/refresh', {})
            time.sleep(2)
            script("document.querySelector('video')?.play().catch(()=>{}); return true;")
            checkpoint('reload_part_two', 2)
        elif args.single:
            reports.clear(); command('/refresh', {}); time.sleep(2)
            script("document.querySelector('video')?.play().catch(()=>{}); return true;")
            checkpoint('reload', int(urllib.parse.parse_qs(parsed.query).get('p', ['1'])[0]))
        evidence['reports_received'] = len(reports)
        evidence['passed'] = len(evidence['stages']) == (1 + args.recommendations if args.recommendations else 2 if args.single else 3) and all(
            stage['latest'] and stage['latest'].get('binding') == 'matched' and
            stage['latest'].get('captured_video', 0) > 0 and stage['latest'].get('captured_audio', 0) > 0
            for stage in evidence['stages'])
        if args.recommendations:
            evidence['passed'] = evidence['passed'] and len({stage['latest'].get('document_sequence') for stage in evidence['stages'] if stage['latest']}) == 1
        (run / 'summary.json').write_text(json.dumps(evidence, ensure_ascii=False, indent=2), encoding='utf8')
        print(json.dumps({'browser_version': evidence['browser_version'], 'passed': evidence['passed'],
                          'stages': [{k: stage['latest'].get(k) for k in ['part', 'binding', 'response_status', 'captured_video', 'captured_audio']}
                                     if stage['latest'] else None for stage in evidence['stages']]}))
        print('Report:', run / 'summary.json')
        if not evidence['passed']: raise SystemExit(1)
    finally:
        if session:
            try: call('DELETE', '/session/' + session)
            except Exception: pass
        driver.terminate(); driver.wait(timeout=10); server.shutdown()

if __name__ == '__main__': main()
