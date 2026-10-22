"""Short authorized test of the installed Debug build; no install or account changes.

Uses app-owned synthetic fixtures, verifies static image lifecycle and frame timing,
then closes test playback. HTTP serves only the generated PNG through an adb reverse.
"""
import argparse
import http.server
import json
from pathlib import Path
import runpy
import struct
import threading
import time
import uuid
import zlib

Device = runpy.run_path(str(Path(__file__).with_name("Test-VideoPipDevice.py")))["Device"]
Suite = runpy.run_path(str(Path(__file__).with_name("Test-VideoPipMatrix.py")))["Suite"]


def fixture(path):
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data))
    width, height = 4096, 2048
    red, green = bytes((225, 40, 25)), bytes((25, 200, 60))
    row = b"\0" + red * (width // 2) + green * (width // 2)
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">2I5B", width, height, 8, 2, 0, 0, 0))
                     + chunk(b"IDAT", zlib.compress(row * height)) + chunk(b"IEND", b""))


def sample(device, suite, name, seconds):
    device.send("hide_menus")
    device.send("perf_tune", quiet=True)
    time.sleep(2)
    label = "pip-image-" + name + "-" + uuid.uuid4().hex[:8]
    device.send("perf_sample", label=label, seconds=seconds)
    device.send("perf_tune", quiet=True)
    deadline = time.monotonic() + seconds + 30
    while time.monotonic() < deadline:
        result = device.read("perf_sample_" + label + ".json")
        if result:
            (device.output / (label + ".json")).write_text(json.dumps(result, indent=2))
            state = suite.observe(name + "-state")
            return {"phase": name, "sample": result, "pip": state["layout"]["pip"]}
        time.sleep(.5)
    raise TimeoutError(label)


def run(args):
    d = Device(args.adb, args.serial, args.output)
    suite = Suite(d, Path("build/output/video-pip/fixtures"), True)
    image = args.output / "pip-reference.png"
    fixture(image)
    data = image.read_bytes()
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path != "/reference": self.send_error(404); return
            self.send_response(200); self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
        def log_message(self, *_args): pass
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    port = server.server_port
    d.command("reverse", f"tcp:{port}", f"tcp:{port}")
    results = []
    try:
        suite.observe("initial")
        initial = d.read("capabilities_latest.json")
        assert initial and initial["xr"]["initialized"] and initial["xr"]["viewport_use_xr"] and initial["xr"]["head_has_tracking_data"] and initial["xr"].get("head_tracking_confidence", 0) > 0, "A valid tracked head pose is required"
        local = d.upload(image)
        for case, clip, projection in [("flat4k", "mp08_4k.mp4", 0), ("vr3608k", "mp08_8k_long.mp4", 3)]:
            suite.open(clip, projection)
            suite.format(projection, 1, swap=False, eye=0, horizontal=0, vertical=0)
            phases = [sample(d, suite, case + "-none", args.seconds)]
            suite.count(3)
            suite.layers(1)
            original = suite.observe(case + "-video-state")["layout"]["pip"]["windows"]
            phases.append(sample(d, suite, case + "-video", args.seconds))
            for slot in (1, 2, 3):
                uri = f"http://127.0.0.1:{port}/reference" if slot == 2 else local
                d.probe(suite.label(case + "-load-image"), "image", slot=slot, uri=uri,
                        predicate=lambda r, s=slot: any(w["slot"] == s and w.get("mode") == "image"
                                                       and not w["image_loading"] and not w["image_error"] for w in r["layout"]["pip"]["windows"]))
                if slot == 1:
                    mixed = suite.observe(case + "-mixed")
                    assert len(mixed["layout"]["pip"]["layers"]) == 2
            still = suite.observe(case + "-all-images", lambda r: r["layout"]["video_layer"]["shown"]
                                  and r["layout"]["pip"]["atlas"] == [0, 0])
            (args.output / (case + "-images.png")).write_bytes(d.command("exec-out", "screencap", "-p"))
            assert all(w["mode"] == "image" and not w["on_layer"] for w in still["layout"]["pip"]["windows"])
            phases.append(sample(d, suite, case + "-image", args.seconds))
            for slot in (1, 2, 3): d.probe(suite.label("restore-video"), "video", slot=slot)
            restored = suite.observe(case + "-restored")["layout"]["pip"]["windows"]
            for before, after in zip(original, restored):
                assert before["slot"] == after["slot"] and before["size"] == after["size"] and before["zoom"] == after["zoom"]
                assert before["center"] == after["center"] and after["mode"] == "video"
            suite.count(0)
            phases.append(sample(d, suite, case + "-none-after", args.seconds))
            results.append({"case": case, "phases": phases})
            (args.output / "summary.json").write_text(json.dumps(results, indent=2))
    finally:
        try: suite.close(); d.send("perf_tune", refresh_rate=0, quiet=True)
        finally: d.command("reverse", "--remove", f"tcp:{port}"); server.shutdown(); server.server_close()
    print("PiP image device lifecycle and timing completed", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--adb", default="adb")
    parser.add_argument("--serial", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--seconds", type=int, default=12)
    run(parser.parse_args())
