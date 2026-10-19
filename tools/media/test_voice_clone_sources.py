"""Exercise production readers on synthetic files and loopback HTTP Range sources.

Run on Linux/WSL after tools/Test-VoiceCloneHost.sh. No device or credentials.
"""
import argparse
import json
from pathlib import Path
import re
import socket
import struct
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from inspect_mp4_layout import boxes, child


def run(command):
    return subprocess.run(command, capture_output=True, text=True, timeout=45)


def split_mp4(source, output):
    """Move all audio chunks behind a 16 MiB gap, keeping real MP4 indexes."""
    data = source.read_bytes()
    top = {kind: (a, b) for kind, a, b in boxes(data)}
    ma, mb = top['moov']
    moov = bytearray(data[ma - 8:mb])
    root = next(boxes(moov))[1:]
    tracks = []
    for kind, a, b in boxes(moov, *root):
        if kind != 'trak':
            continue
        mdia = child(moov, (a, b), 'mdia')
        hdlr = child(moov, mdia, 'hdlr')
        audio = moov[hdlr[0] + 8:hdlr[0] + 12] == b'soun'
        stbl = child(moov, child(moov, mdia, 'minf'), 'stbl')
        stco = child(moov, stbl, 'stco')[0]
        count = struct.unpack_from('>I', moov, stco + 4)[0]
        for i in range(count):
            at = stco + 8 + i * 4
            tracks.append((struct.unpack_from('>I', moov, at)[0], at, audio))
    ordered = sorted(tracks)
    ends = {offset: ordered[i + 1][0] if i + 1 < len(ordered) else top['mdat'][1]
            for i, (offset, _, _) in enumerate(ordered)}
    fa, fb = top['ftyp']
    ftyp = data[fa - 8:fb]
    payload = bytearray()
    base = len(ftyp) + len(moov) + 8
    for audio in (False, True):
        if audio:
            payload.extend(bytes(16 * 1024 * 1024))
        for offset, at, is_audio in ordered:
            if is_audio == audio:
                struct.pack_into('>I', moov, at, base + len(payload))
                payload.extend(data[offset:ends[offset]])
    output.write_bytes(ftyp + moov + struct.pack('>I4s', len(payload) + 8, b'mdat') + payload)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ffmpeg', default='ffmpeg')
    parser.add_argument('--baseline', type=Path)
    parser.add_argument('--split-latency-ms', type=int, default=0)
    args = parser.parse_args()
    assert 0 <= args.split_latency_ms <= 500
    repo = Path(__file__).resolve().parents[2]
    output = repo / 'build/output/voice-clone-sources-20261020'
    output.mkdir(parents=True, exist_ok=True)
    binary = output / 'readers-host'
    captions = output / 'caption.srt'
    captions.write_text('1\n00:00:03,000 --> 00:00:08,000\nFirst clear sentence.\n\n'
                        '2\n00:00:13,000 --> 00:00:18,000\nSecond clear sentence.\n\n'
                        '3\n00:00:27,000 --> 00:00:32,000\nThird clear sentence.\n', encoding='utf-8')
    late_captions = output / 'late-caption.srt'
    late_captions.write_text('1\n00:00:30,000 --> 00:00:35,000\nLate first sentence.\n\n'
                             '2\n00:01:15,000 --> 00:01:20,000\nLater second sentence.\n', encoding='utf-8')

    def media_path(path):
        if args.ffmpeg.endswith('.exe'):
            return subprocess.check_output(['wslpath', '-w', str(path)], text=True).strip()
        return str(path)

    source = output / 'indexed.mp4'
    cmd = [args.ffmpeg, '-hide_banner', '-loglevel', 'error', '-y',
           '-f', 'lavfi', '-i', 'testsrc2=size=320x180:rate=10:duration=40',
           '-f', 'lavfi', '-i', 'sine=frequency=320:sample_rate=48000:duration=40',
           '-i', media_path(captions), '-map', '0:v', '-map', '1:a', '-map', '2:s',
           '-c:v', 'libx264', '-preset', 'ultrafast', '-g', '100', '-c:a', 'aac',
           '-c:s', 'mov_text', '-movflags', '+faststart', media_path(source)]
    generated = run(cmd)
    assert generated.returncode == 0, generated.stderr
    for name, extra in [('indexed.mkv', ['-c:s', 'srt']), ('indexed.ts', ['-sn'])]:
        generated = run([args.ffmpeg, '-hide_banner', '-loglevel', 'error', '-y',
                         '-i', media_path(source), '-map', '0', '-c', 'copy', *extra, media_path(output / name)])
        assert generated.returncode == 0, generated.stderr
    split_mp4(source, output / 'split.mp4')
    stats = {'requests': 0, 'bytes': 0, 'ranges': []}
    lock = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            path = output / self.path.lstrip('/')
            if path.parent != output or not path.is_file():
                self.send_error(404)
                return
            size = path.stat().st_size
            span = re.fullmatch(r'bytes=(\d+)-(\d*)', self.headers.get('Range', 'bytes=0-'))
            if not span:
                self.send_error(416)
                return
            start, end = int(span[1]), int(span[2] or size - 1)
            end = min(end, size - 1)
            if not 0 <= start <= end < size:
                self.send_error(416)
                return
            with lock:
                stats['requests'] += 1
                stats['ranges'].append(start)
            if path.name == 'split.mp4':
                time.sleep(args.split_latency_ms / 1000)
            self.connection.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 16 * 1024)
            self.send_response(206)
            self.send_header('Content-Type', 'application/octet-stream')
            self.send_header('Accept-Ranges', 'bytes')
            self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
            self.send_header('Content-Length', str(end - start + 1))
            self.send_header('Connection', 'close')
            self.end_headers()
            try:
                with path.open('rb') as stream:
                    stream.seek(start)
                    left = end - start + 1
                    while left:
                        block = stream.read(min(left, 16 * 1024))
                        self.wfile.write(block)
                        left -= len(block)
                        with lock:
                            stats['bytes'] += len(block)
                        time.sleep(.001)
            except (BrokenPipeError, ConnectionResetError):
                pass

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    results = []
    try:
        for mode, name, index in [('audio', 'indexed.mp4', 1), ('audio', 'split.mp4', 1),
                                  ('audio', 'indexed.mkv', 1), ('audio', 'indexed.ts', 1),
                                  ('subtitles', 'caption.srt', 0), ('subtitles', 'indexed.mkv', 2),
                                  ('subtitles', 'indexed.mp4', 2)]:
            for remote in (False, True):
                with lock:
                    stats.update(requests=0, bytes=0, ranges=[])
                url = f'http://127.0.0.1:{server.server_port}/{name}' if remote else str(output / name)
                destination = output / f'{name}-{remote}.wav'
                begun = time.monotonic()
                proc = run([str(binary), mode, url, str(index), '13' if mode == 'audio' else '0',
                            '18' if mode == 'audio' else '40', str(destination)])
                assert proc.returncode == 0, (mode, name, remote, proc.stderr)
                if mode == 'audio':
                    assert destination.stat().st_size == 960044
                    pcm = struct.unpack('<480000h', destination.read_bytes()[44:])
                    assert sum(v * v for v in pcm) / len(pcm) > 1000
                    if remote and name == 'split.mp4':
                        assert stats['requests'] < 8, 'Audio extraction must not alternate video ranges'
                else:
                    cues = json.loads(proc.stdout)['cues']
                    assert len(cues) == 3, (name, cues)
                    assert 'Second clear sentence.' in cues[1]['text']
                results.append({'mode': mode, 'fixture': name, 'http': remote,
                                'seconds': round(time.monotonic() - begun, 4),
                                'requests': stats['requests'], 'server_written_bytes': stats['bytes'], 'passed': True})
        for remote in (False, True):
            url = f'http://127.0.0.1:{server.server_port}/late-caption.srt' if remote else str(late_captions)
            for begin, end, expected in [(8.5, 60, 1), (32, 60, 1), (100, 120, 0)]:
                proc = run([str(binary), 'subtitles', url, '0', str(begin), str(end), str(output / 'unused.wav')])
                assert proc.returncode == 0, (remote, begin, proc.stderr)
                result = json.loads(proc.stdout)
                assert len(result['cues']) == expected, (remote, begin, result)
                if expected:
                    assert 'Late first sentence.' in result['cues'][0]['text']
                else:
                    assert result['eof'], result
                results.append({'mode': 'subtitle-boundary', 'fixture': 'late-caption.srt',
                                'http': remote, 'start': begin, 'end': end, 'cues': expected, 'passed': True})
        if args.baseline:
            for name in ('indexed.mp4', 'split.mp4', 'indexed.mkv'):
                with lock:
                    stats.update(requests=0, bytes=0, ranges=[])
                proc = run([str(args.baseline.resolve()), 'audio', f'http://127.0.0.1:{server.server_port}/{name}',
                            '1', '13', '18', str(output / 'baseline.wav')])
                results.append({'mode': 'baseline-audio', 'fixture': name, 'http': True,
                                'passed': proc.returncode == 0, 'error': proc.stderr[-300:],
                                'requests': stats['requests'], 'server_written_bytes': stats['bytes']})
    finally:
        server.shutdown()
        server.server_close()
    (output / 'results.json').write_text(json.dumps(results, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(results, indent=2))


if __name__ == '__main__':
    main()
