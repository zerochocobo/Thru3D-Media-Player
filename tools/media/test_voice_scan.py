"""Production native VAD, stream selection, range, EOF and cancellation on synthetic media.

Run on Linux/WSL after Test-VoiceScanHost.sh; --speech-wav is reproducible synthetic
speech (for example Windows System.Speech). No user media, credentials or device.
"""
import argparse
import json
from pathlib import Path
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import wave


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--speech-wav', required=True, type=Path)
    parser.add_argument('--ffmpeg', default='ffmpeg')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    output = root / 'build/output/voice-scan-host'
    output.mkdir(parents=True, exist_ok=True)
    binary = output / 'scan-host'
    manifest = json.loads((root / 'third_party/narration/vad_model.json').read_text())
    model = root / 'models/narration' / manifest['id'] / 'silero_vad.onnx'
    results = []
    def media_path(path):
        return subprocess.check_output(['wslpath', '-w', str(path.resolve())], text=True).strip() if args.ffmpeg.endswith('.exe') else str(path)

    def run(mode, source, stream=1, start=2, end=10, target=model, success=True):
        result = subprocess.run([str(binary), mode, str(source), str(stream), str(start), str(end), str(target)], capture_output=True, text=True, timeout=45)
        assert (result.returncode == 0) == success, (mode, source, result.stderr)
        return json.loads(result.stdout) if result.stdout and success else result

    for extension in ('mp4', 'mkv'):
        source = output / ('fixture.' + extension)
        subprocess.run([args.ffmpeg, '-hide_banner', '-loglevel', 'error', '-y', '-f', 'lavfi', '-i', 'color=c=black:s=160x90:r=1',
                        '-i', media_path(args.speech_wav), '-f', 'lavfi', '-i', 'anullsrc=r=16000:cl=mono',
                        '-map', '0:v', '-map', '1:a', '-map', '2:a', '-t', '14', '-c:v', 'libx264', '-preset', 'ultrafast',
                        '-c:a', 'aac', '-metadata:s:a:0', 'language=eng', media_path(source)], check=True)
        probe = run('probe', source)
        assert len(probe['audio_tracks']) == 2 and probe['audio_tracks'][0]['stream_index'] == 1
        assert 13 < probe['duration'] < 15
        speech = run('scan', source)
        assert speech['done'] and not speech['cancelled'] and speech['callbacks'] >= 7
        assert len(speech['frames']) == 250
        assert sum(frame[1] > .55 for frame in speech['frames']) > 100
        assert abs(speech['frames'][0][0] - 2) < .001 and speech['frames'][-1][0] < 10
        silence = run('scan', source, stream=2)
        assert sum(frame[1] > .55 for frame in silence['frames']) == 0
        cancelled = run('cancel', source)
        assert cancelled['callbacks'] == 1 and cancelled['cancelled'] and not cancelled['done']
        eof = run('scan', source, start=11, end=40)
        assert eof['done'] and eof['frames'][-1][0] < 15
        run('scan', source, stream=0, success=False)
        run('scan', source, start=0, end=601, success=False)
        run('scan', source, target=output / 'missing.onnx', success=False)
        wav = output / ('manual-' + extension + '.wav')
        run('extract', source, start=3, end=9, target=wav)
        with wave.open(str(wav)) as audio:
            assert audio.getframerate() == 48000 and audio.getnchannels() == 2 and audio.getnframes() == 288000
        data = source.read_bytes()
        transfers = []

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_): pass
            def do_GET(self):
                value = self.headers.get('Range', '')
                start, end = 0, len(data)-1
                if value.startswith('bytes='):
                    first, last = value[6:].split('-', 1)
                    start = int(first); end = min(int(last), end) if last else end
                body = data[start:end+1]
                transfers.append(len(body))
                self.send_response(206 if value else 200)
                self.send_header('Content-Length', str(len(body)))
                self.send_header('Accept-Ranges', 'bytes')
                if value: self.send_header('Content-Range', f'bytes {start}-{end}/{len(data)}')
                self.end_headers()
                try: self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError): pass

        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        try:
            remote = run('scan', f'http://127.0.0.1:{server.server_port}/fixture.{extension}')
            assert remote['frames'] == speech['frames']
            assert len(transfers) < 20 and sum(transfers) < len(data)*10
        finally:
            server.shutdown(); server.server_close(); thread.join()
        results.append({'format': extension, 'frames': len(speech['frames']), 'speech_frames': sum(frame[1]>.55 for frame in speech['frames']),
                        'http_requests': len(transfers), 'http_bytes': sum(transfers), 'cancel_callbacks': cancelled['callbacks'], 'manual_seconds': 6})
    (output / 'results.json').write_text(json.dumps({'model': manifest['id'], 'results': results, 'failures': 0}, indent=2))
    print(json.dumps({'results': results, 'failures': 0}))


if __name__ == '__main__': main()
