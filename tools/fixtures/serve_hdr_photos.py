"""Disposable read-only WebDAV fixtures on PC loopback, for adb reverse.

No user credentials, writes or LAN listener. Stop with --stop-file.
"""
import argparse
import email.utils
import http.server
import json
import logging
import os
import re
import threading
import time
import urllib.parse
from pathlib import Path
from xml.sax.saxutils import escape

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--hdr', type=Path, required=True)
p.add_argument('--exr', type=Path, required=True)
p.add_argument('--root', type=Path, default=Path('tmp/hdr-photos/served'))
p.add_argument('--stop-file', type=Path, default=Path('tmp/hdr-photos/server-stop'))
args = p.parse_args()
root = args.root.resolve(); root.mkdir(parents=True, exist_ok=True)
for source, name in [(args.hdr, 'poly_360_2D.hdr'), (args.exr, 'poly_360_2D.exr')]:
    source = source.resolve(); target = root/name
    if target.exists():
        if not target.samefile(source): raise ValueError('Existing fixture alias belongs to another source')
    else: os.link(source, target)
files = {f.name: f for f in root.iterdir() if f.name in ['poly_360_2D.hdr', 'poly_360_2D.exr']}
if len(list(root.iterdir())) != 2: raise ValueError('Fixture folder must contain only two test aliases')


class Dav(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *_): pass
    def do_PROPFIND(self):
        name = urllib.parse.unquote(urllib.parse.urlsplit(self.path).path).strip('/')
        if name and name not in files: self.send_error(404); return
        entries = [(name, files.get(name))] if name else [('', None)]+list(files.items())
        rows = []
        for label, file in entries:
            length = file.stat().st_size if file else 0
            href = '/'+urllib.parse.quote(label)+(('/' if label else '') if not file else '')
            props = f'<d:displayname>{escape(label)}</d:displayname><d:getcontentlength>{length}</d:getcontentlength><d:getlastmodified>Tue, 20 Oct 2026 00:00:00 GMT</d:getlastmodified><d:getetag>"{length}"</d:getetag>'
            props += '<d:resourcetype>'+('' if file else '<d:collection/>')+'</d:resourcetype>'
            props += '<d:getcontenttype>'+('image/x-exr' if label.endswith('.exr') else 'image/vnd.radiance')+'</d:getcontenttype>'
            rows.append(f'<d:response><d:href>{href}</d:href><d:propstat><d:prop>{props}</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>')
        body = ('<?xml version="1.0"?><d:multistatus xmlns:d="DAV:">'+''.join(rows)+'</d:multistatus>').encode()
        self.send_response(207); self.send_header('Content-Type','application/xml'); self.send_header('Content-Length',str(len(body))); self.end_headers(); self.wfile.write(body)
        # Consume a PROPFIND request body before HTTP keepalive reuses this connection.
        length = int(self.headers.get('Content-Length', '0'))
        if length: self.rfile.read(min(length, 65536))
    def do_HEAD(self): self.serve(False)
    def do_GET(self): self.serve(True)
    def serve(self, body):
        name = urllib.parse.unquote(urllib.parse.urlsplit(self.path).path).strip('/')
        if name not in files: self.send_error(404); return
        file = files[name]; size = file.stat().st_size; start, end = 0, size-1
        match = re.fullmatch(r'bytes=(\d+)-(\d*)', self.headers.get('Range',''))
        if match: start=int(match[1]); end=min(size-1,int(match[2])) if match[2] else size-1
        if start>end or start>=size: self.send_error(416); return
        self.send_response(206 if match else 200)
        self.send_header('Content-Length',str(end-start+1)); self.send_header('Accept-Ranges','bytes')
        self.send_header('Content-Type','image/x-exr' if name.endswith('.exr') else 'image/vnd.radiance')
        self.send_header('Last-Modified',email.utils.formatdate(file.stat().st_mtime,usegmt=True))
        if match: self.send_header('Content-Range',f'bytes {start}-{end}/{size}')
        self.end_headers(); sent=0
        if body:
            try:
                with file.open('rb') as stream:
                    stream.seek(start)
                    while sent<end-start+1:
                        data=stream.read(min(262144,end-start+1-sent))
                        if not data: break
                        self.wfile.write(data);sent+=len(data)
            except (ConnectionError,OSError): pass
            print(json.dumps({'protocol':'webdav','file':name,'start':start,'bytes':sent}),flush=True)


logging.disable(logging.CRITICAL)
http = http.server.ThreadingHTTPServer(('127.0.0.1', 28871), Dav)
threading.Thread(target=http.serve_forever,daemon=True).start()
print('Read-only fixture server ready: loopback WebDAV 28871',flush=True)
try:
    while not args.stop_file.exists(): time.sleep(.5)
finally:
    http.shutdown(); http.server_close()
    # Only our two hard links, never traverse or remove the input source files.
    for file in files.values(): file.unlink(missing_ok=True)
    root.rmdir()
    print('Fixture servers stopped and aliases removed',flush=True)
