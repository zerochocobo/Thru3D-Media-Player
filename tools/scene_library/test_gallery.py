"""Desktop check of the scene gallery's downloader against a local file server.

Usage: python -I -X utf8 test_gallery.py [godot]

Serves generated files with Range support on 127.0.0.1, then runs
app/godot/tests/test_scene_gallery.gd headless against it: a whole download, a resumed one,
a resumed one whose first half is wrong, a file the server no longer has, and a cancel.
"""
import hashlib
import http.server
import json
import os
import subprocess
import sys
import threading

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
WORK = os.path.join(ROOT, "build", "output", "scene-gallery")
SERVED = os.path.join(WORK, "served", "scenes")


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    requests = []

    def do_GET(self):
        path = os.path.join(SERVED, os.path.basename(self.path))
        Handler.requests.append((os.path.basename(self.path), self.headers.get("Range", "")))
        if not self.path.startswith("/scenes/") or not os.path.isfile(path):
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        with open(path, "rb") as fh:
            data = fh.read()
        start = 0
        ranged = self.headers.get("Range", "")
        if ranged.startswith("bytes="):
            start = int(ranged[6:].split("-")[0])
            if start >= len(data):
                self.send_response(416)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            self.send_response(206)
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, len(data) - 1, len(data)))
        else:
            self.send_response(200)
        body = data[start:]
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        # Slowly enough that a cancel lands mid-file.
        slow = "slow" in self.path
        for at in range(0, len(body), 65536):
            try:
                self.wfile.write(body[at:at + 65536])
                if slow:
                    threading.Event().wait(0.05)
            except OSError:
                return

    def log_message(self, *_):
        pass


def fixture(name, size, seed):
    data = hashlib.sha256(seed).digest() * (size // 32)
    with open(os.path.join(SERVED, name), "wb") as fh:
        fh.write(data)
    return {"file": name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}


def main(godot):
    os.makedirs(SERVED, exist_ok=True)
    scenes = []
    for slug, size in (("whole", 600_000), ("resumed", 900_000), ("spoiled", 900_000), ("slow", 8_000_000)):
        scenes.append({"slug": slug, "title": slug.title(), "author": "Tester", "license": "CC BY 4.0", "source": "https://example.invalid/" + slug,
                       "tiers": {"high": fixture(slug + ".high.glb", size, slug.encode())}})
    gone = {"file": "gone.high.glb", "bytes": 64, "sha256": "0" * 64}
    scenes.append({"slug": "gone", "title": "Gone", "author": "Tester", "license": "CC BY 4.0", "source": "", "tiers": {"high": gone}})
    scenes.append({"slug": "../escape", "title": "Bad", "tiers": {"high": gone}})
    scenes.append({"slug": "badfile", "title": "Bad", "tiers": {"high": {"file": "../../x.glb", "bytes": 5, "sha256": "0" * 64}}})
    with open(os.path.join(WORK, "catalog.json"), "w", encoding="utf-8") as fh:
        json.dump({"version": 1, "scenes": scenes}, fh)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.handle_error = lambda *_: None   # a cancelled download drops its connection
    threading.Thread(target=server.serve_forever, daemon=True).start()
    env = dict(os.environ, THRU3D_GALLERY_PORT=str(server.server_address[1]), THRU3D_GALLERY_WORK=WORK.replace("\\", "/"))
    result = subprocess.run([godot, "--headless", "--xr-mode", "off", "--path", os.path.join(ROOT, "app", "godot"), "--script",
                             "res://tests/test_scene_gallery.gd"], env=env, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=300)
    server.shutdown()
    lines = [line for line in result.stdout.splitlines() if line.startswith(("Scene gallery", "FAIL", "SCRIPT ERROR", "ERROR"))]
    print("\n".join(lines))
    ranged = {name: value for name, value in Handler.requests if value}
    ok = result.returncode == 0 and any("0 failures" in line for line in lines) and "resumed.high.glb" in ranged
    if "resumed.high.glb" not in ranged:
        print("FAIL the resumed download did not ask for a byte range")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "godot")
