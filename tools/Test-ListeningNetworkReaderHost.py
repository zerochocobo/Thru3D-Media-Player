"""Run on Linux/WSL with an owned interleaved MP4 and the production reader-host.

Compare normal MOV AVIO buffering with audio-only direct reads over a loopback
Range server. Both runs must emit identical PCM; direct reads must avoid video.
"""
import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import re
import subprocess
import threading
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('fixture', type=Path)
parser.add_argument('--reader', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
size = args.fixture.stat().st_size


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        match = re.fullmatch(r'bytes=(\d+)-(\d*)', self.headers.get('Range', 'bytes=0-'))
        if not match:
            self.send_error(416)
            return
        start = int(match[1])
        end = min(size-1, int(match[2]) if match[2] else size-1)
        self.send_response(206)
        self.send_header('Content-Length', str(end-start+1))
        self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
        self.send_header('Accept-Ranges', 'bytes')
        self.end_headers()
        try:
            with args.fixture.open('rb') as file:
                file.seek(start)
                while start <= end:
                    data = file.read(min(65536, end-start+1))
                    if not data:
                        break
                    self.wfile.write(data)
                    start += len(data)
        except (BrokenPipeError, ConnectionResetError):
            pass


server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
results = {}
try:
    for mode in ('buffered', 'direct', 'input', 'input-yield'):
        output = args.output/(mode+'.f32')
        command = [str(args.reader), f'http://127.0.0.1:{server.server_port}/owned.mp4',
                   '1', '0', str(output), '0']
        if mode == 'buffered':
            command.append('buffered')
        elif mode.startswith('input'):
            command[1] = str(args.fixture)
            command.append(mode)
        began = time.monotonic()
        run = subprocess.run(command, capture_output=True, check=True, timeout=120)
        (args.output/(mode+'.log')).write_bytes(run.stderr)
        result = json.loads(run.stdout)
        result['elapsed_seconds'] = time.monotonic()-began
        result['pcm_sha256'] = hashlib.sha256(output.read_bytes()).hexdigest()
        results[mode] = result
finally:
    server.shutdown()
    server.server_close()
    thread.join()
assert results['buffered']['samples'] > 16000*10
assert results['direct']['audio_spans'] > 0
assert results['buffered']['pcm_sha256'] == results['direct']['pcm_sha256'], 'Audio changed'
assert results['input']['pcm_sha256'] == results['direct']['pcm_sha256'], 'Direct source audio changed'
assert results['input-yield']['budget_yielded']
assert results['input-yield']['pcm_sha256'] == results['input']['pcm_sha256'], 'Budget expiry lost or duplicated audio'
assert results['input']['demux_bytes_read'] < results['buffered']['demux_bytes_read']*.1
ratio = results['direct']['demux_bytes_read']/results['buffered']['demux_bytes_read']
assert ratio < .1, f'Audio-only reader still downloads video: {ratio}'
report = dict(passed=True, input_bytes=size, direct_to_buffered_bytes_ratio=ratio, cases=results)
(args.output/'report.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
print(json.dumps(report, indent=2))
