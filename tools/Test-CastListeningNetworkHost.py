"""Exercise the production cast audio reader against a synthetic loopback source.

Run on Linux/WSL through Test-CastListeningNetworkHost.sh. No headset, user
media, translation service, or speech model is used. This verifies audio
timestamps, HTTP errors, finite requests and blocked-I/O cancellation; it is
not an Android or primary-video playback performance test.
"""
import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import re
import subprocess
import threading


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reader", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--ffmpeg", default="ffmpeg")
    parser.add_argument("--fixture", type=Path, help="An owned MP4 with video stream 0 and audio stream 1; otherwise generate a synthetic fixture")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    fixture = args.fixture or args.output / "owned-synthetic.mp4"
    if args.fixture is None:
        subprocess.run([args.ffmpeg, "-v", "error", "-y", "-f", "lavfi", "-i",
                        "testsrc2=size=640x360:rate=24:duration=12", "-f", "lavfi", "-i",
                        "sine=frequency=440:sample_rate=48000:duration=12", "-map", "0:v", "-map", "1:a",
                        "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac",
                        "-movflags", "+faststart", str(fixture)], check=True, timeout=45)
    body = fixture.read_bytes()
    requests, gates, results = [], [], []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def do_GET(self):
            kind = self.path.strip("/")
            requests.append({"kind": kind, "range": self.headers.get("Range", "")})
            if kind.isdigit():
                self.send_error(int(kind)); return
            if kind == "stall-headers":
                gate = threading.Event(); gates.append(gate); gate.wait(5)
                return
            match = re.fullmatch(r"bytes=(\d+)-(\d*)", self.headers.get("Range", "bytes=0-"))
            if not match:
                self.send_error(416); return
            start, end = int(match[1]), min(len(body)-1, int(match[2]) if match[2] else len(body)-1)
            if kind == "ignore-range":
                start, end = 0, len(body)-1
            if start > end:
                self.send_error(416); return
            self.send_response(200 if kind == "ignore-range" else 206)
            self.send_header("Content-Length", str(end-start+1))
            if kind != "ignore-range":
                self.send_header("Content-Range", f"bytes {start}-{end}/{len(body)}")
                self.send_header("Accept-Ranges", "bytes")
            self.end_headers()
            try:
                if kind == "stall-body":
                    self.wfile.flush()
                    gate = threading.Event(); gates.append(gate); gate.wait(5)
                elif kind == "disconnect":
                    self.wfile.write(body[start:min(end+1, start+64)])
                else:
                    self.wfile.write(body[start:end+1])
            except (BrokenPipeError, ConnectionResetError):
                pass
            self.close_connection = True

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()

    def run(kind, start=0, mode="read", local=False):
        before = len(requests)
        pcm = args.output / f"{kind}-{start}-{mode}.f32"
        path = str(fixture) if local else f"http://127.0.0.1:{server.server_port}/{kind}"
        process = subprocess.run([str(args.reader), path, str(start), mode, str(pcm)], capture_output=True, timeout=20)
        record = json.loads(process.stdout)
        record.update(kind=kind, start=start, mode=mode, exit=process.returncode,
                      requests=requests[before:].copy(), pcm_sha256=hashlib.sha256(pcm.read_bytes()).hexdigest() if pcm.exists() else "")
        results.append(record)
        (args.output / f"{kind}-{start}-{mode}.log").write_bytes(process.stderr)
        for gate in gates:
            gate.set()
        print(json.dumps(record), flush=True)
        return record

    try:
        for start in (0, 5):
            local = run("local", start, local=True)
            remote = run("range", start)
            assert local["ok"] and remote["ok"] and remote["samples"] > 16000
            assert local["samples"] == remote["samples"] and local["pcm_sha256"] == remote["pcm_sha256"], "HTTP audio/timing changed"
        ignored = run("ignore-range", 5)
        assert ignored["seconds"] < 5 and len(ignored["requests"]) < 20, "Ignored ranges caused unbounded work"
        if ignored["ok"]:
            assert ignored["pcm_sha256"] == results[2]["pcm_sha256"], "Non-range source returned wrong audio position"
        for status in (401, 403, 404, 429, 503):
            error = run(str(status))
            assert not error["ok"] and error["exit"] == 1 and len(error["requests"]) <= 2, "HTTP error did not fail finitely"
        disconnected = run("disconnect")
        assert not disconnected["ok"] and disconnected["seconds"] < 5, "Disconnected source did not fail"
        for kind in ("stall-headers", "stall-body"):
            cancelled = run(kind, mode="cancel")
            assert cancelled["cancelled"] and not cancelled["ok"] and cancelled["seconds"] < 2, "Blocked HTTP cancellation exceeded two seconds"
        final = run("range")
        assert final["ok"] and final["pcm_sha256"] == results[0]["pcm_sha256"], "Prior failed reader affected the next source"
        (args.output / "verification.json").write_text(json.dumps({"passed": True, "cases": results,
            "scope": "Production AudioReader, directAudio=false, loopback HTTP; no primary video or headset benchmark"}, indent=2), encoding="utf-8")
    finally:
        for gate in gates:
            gate.set()
        server.shutdown(); server.server_close(); thread.join()


if __name__ == "__main__":
    main()
