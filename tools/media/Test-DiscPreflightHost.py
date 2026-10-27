"""Exercise a stalled ISO then later opens on the same source worker/process.

Run against the host MVC FFmpeg build. --legacy demonstrates the former
uncancellable entry point failing the recovery deadline; it does not change libs.
"""
import argparse
import concurrent.futures
import ctypes
import http.server
import json
import re
import threading
import time
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--binary-dir', type=Path, required=True)
parser.add_argument('--iso', type=Path)
parser.add_argument('--legacy', action='store_true')
args = parser.parse_args()

entered = threading.Event()
unblock = threading.Event()


class Origin(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        total = 128 * 1024
        match = re.fullmatch(r'bytes=(\d+)-(\d*)', self.headers.get('Range', 'bytes=0-'))
        start = int(match[1])
        end = min(int(match[2]) if match[2] else total - 1, total - 1)
        self.send_response(206)
        self.send_header('Content-Length', str(end - start + 1))
        self.send_header('Content-Range', f'bytes {start}-{end}/{total}')
        self.end_headers()
        if self.path == '/stalled.iso':
            entered.set()
            unblock.wait(3)
            return
        try:
            self.wfile.write(bytes(end - start + 1))
        except (BrokenPipeError, ConnectionResetError):
            pass


root = args.binary_dir.resolve()
for name in ('avutil', 'swresample', 'avcodec'):
    ctypes.CDLL(str(root / f'lib{name}' / f'lib{name}.so'), mode=ctypes.RTLD_GLOBAL)
lib = ctypes.CDLL(str(root / 'libavformat/libavformat.so'), mode=ctypes.RTLD_GLOBAL)
callback_type = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p)
probe = getattr(lib, 'avformat_thru3d_bd_titles' if args.legacy else 'avformat_thru3d_bd_titles_v2')
integer = ctypes.POINTER(ctypes.c_int)
probe.argtypes = [ctypes.c_char_p, ctypes.c_int, integer, integer, ctypes.POINTER(ctypes.c_int64),
                  integer, integer, ctypes.c_void_p, ctypes.c_int]
if not args.legacy:
    probe.argtypes += [callback_type, ctypes.c_void_p]
probe.restype = ctypes.c_int


def read(url, cancelled):
    width, height, mvc, selected = (ctypes.c_int() for _ in range(4))
    duration = ctypes.c_int64()
    titles = ctypes.create_string_buffer(16384)
    callback = callback_type(lambda _: int(cancelled.is_set()))
    values = [url.encode(), -1, ctypes.byref(width), ctypes.byref(height), ctypes.byref(duration),
              ctypes.byref(mvc), ctypes.byref(selected), titles, len(titles)]
    if not args.legacy:
        values += [callback, None]
    result = probe(*values)
    return {'result': result, 'width': width.value, 'height': height.value, 'mvc': bool(mvc.value)}


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Origin)
threading.Thread(target=server.serve_forever, daemon=True).start()
base = f'http://127.0.0.1:{server.server_port}'
results = []
try:
    with concurrent.futures.ThreadPoolExecutor(max_workers=1) as worker:
        cancelled = threading.Event()
        pending = worker.submit(read, base + '/stalled.iso', cancelled)
        assert entered.wait(2), 'Probe never reached the HTTP source'
        started = time.monotonic()
        cancelled.set()
        first = pending.result(timeout=5)
        first.update(case='cancel_stalled', elapsed_ms=round((time.monotonic() - started) * 1000))
        results.append(first)
        assert first['result'] < 0 and first['elapsed_ms'] < 1000, first
        second = worker.submit(read, base + '/invalid.iso', threading.Event()).result(timeout=2)
        second.update(case='next_invalid_disc')
        results.append(second)
        assert second['result'] < 0, second
        if args.iso:
            for index in range(2):
                healthy = worker.submit(read, str(args.iso.resolve()), threading.Event()).result(timeout=30)
                healthy.update(case=f'next_valid_disc_{index}')
                results.append(healthy)
                assert healthy['result'] == 0 and healthy['width'] > 0 and healthy['height'] > 0, healthy
finally:
    unblock.set()
    server.shutdown()
    server.server_close()
    print(json.dumps(results, indent=2), flush=True)
