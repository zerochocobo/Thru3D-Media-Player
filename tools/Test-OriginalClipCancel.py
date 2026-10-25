"""Linux/WSL integration: interrupt production FFmpeg I/O, then export with a fresh control.

Requires the host libraries from Test-OriginalClipHost.sh and the avc.mp4 fixture from
Test-OriginalCapture.py prepare. All generated sources/results stay under build/.
"""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import subprocess
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/output/clip-cancel"
LIBS = ROOT / "build/capture-ffmpeg-host"
SOURCE = r'''
#include "original_clip_core.h"
#include <iostream>
#include <thread>
int main(int argc, char** argv) {
    if (argc != 4) return 2;
    quest::capture::Control control;
    std::string result;
    auto copy = [&] { result = quest::capture::clip(argv[1], argv[2], 0, 2000000, -2,
        "", "", "{\"version\":1,\"geometry\":0}", control); };
    if (std::string(argv[3]) == "cancel") {
        std::thread worker(copy);
        std::cin.get();
        control.cancelled.store(true);
        worker.join();
    } else copy();
    std::cout << result.substr(0, result.size()-1) << ",\"cancelled\":"
        << (control.cancelled.load() ? "true" : "false") << "}" << std::endl;
}
'''


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    source = OUT / "cancel-host.cpp"
    binary = OUT / "cancel-host"
    source.write_text(SOURCE)
    directories = [LIBS / name for name in ("libavformat", "libavcodec", "libavutil")]
    subprocess.run(["g++", "-std=c++17", "-Wall", "-Wextra", "-Werror", "-pthread",
                    "-I" + str(ROOT / "native/mpv"), "-I" + str(ROOT / "native/mpv/include/ffmpeg"),
                    str(source), *["-L" + str(path) for path in directories],
                    "-lavformat", "-lavcodec", "-lavutil",
                    "-Wl,-rpath," + ":".join(map(str, directories)), "-o", str(binary)], check=True)
    entered, release = threading.Event(), threading.Event()

    class StalledSource(BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.send_header("Content-Length", "1048576")
            self.send_header("Accept-Ranges", "bytes")
            self.end_headers()
            entered.set()
            release.wait(10)

        def log_message(self, *_args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), StalledSource)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    output = OUT / "cancelled.output"
    output.unlink(missing_ok=True)
    process = subprocess.Popen([str(binary), f"http://127.0.0.1:{server.server_port}/stalled.mp4",
                                str(output), "cancel"], text=True, stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        assert entered.wait(5), "Production FFmpeg reader never reached the stalled source"
        start = time.monotonic()
        stdout, stderr = process.communicate(input="x", timeout=5)
        elapsed = time.monotonic() - start
        report = json.loads(stdout)
        assert process.returncode == 0 and report["state"] == "error" and report["cancelled"], report
        assert elapsed < 3, f"Cancellation waited {elapsed:.3f}s for the network timeout"
        assert not output.exists(), "Blocked input unexpectedly published an output"
        (OUT / "native-cancel.stderr.log").write_text(stderr)
    finally:
        if process.poll() is None:
            process.kill()
            process.communicate()
        release.set()
        server.shutdown()
        server.server_close()
        thread.join(5)
    retry = OUT / "retry.output"
    result = subprocess.run([str(binary), str(ROOT / "build/output/original-capture/avc.mp4"),
                             str(retry), "copy"], text=True, capture_output=True, check=True)
    resumed = json.loads(result.stdout)
    assert resumed["state"] == "saved" and not resumed["cancelled"] and retry.stat().st_size > 0, resumed
    evidence = {"state": "passed", "cancel_latency_ms": round(elapsed * 1000),
                "blocked_reader": report, "retry": resumed,
                "scope": "Production native clip core; Android MediaStore cleanup is not exercised by this host test"}
    (OUT / "native-verification.json").write_text(json.dumps(evidence, indent=2))
    print(f"Native clip cancellation passed: stalled reader interrupted in {elapsed * 1000:.0f} ms; fresh export saved")


if __name__ == "__main__":
    main()
