"""Test end-file HTTP status using a host build of the pinned libmpv and loopback only."""

from collections import Counter
import ctypes as C
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
from pathlib import Path
import socket
import sys
from threading import Thread
from time import monotonic
import wave


class Event(C.Structure):
    _fields_ = [("id", C.c_int), ("error", C.c_int), ("user", C.c_uint64), ("data", C.c_void_p)]


class EndFile(C.Structure):
    _fields_ = [("reason", C.c_int), ("error", C.c_int), ("entry", C.c_int64)]


class Hook(C.Structure):
    _fields_ = [("name", C.c_char_p), ("id", C.c_uint64)]


class Node(C.Structure):
    pass


class NodeList(C.Structure):
    _fields_ = [("count", C.c_int), ("values", C.POINTER(Node)), ("keys", C.POINTER(C.c_char_p))]


class Value(C.Union):
    _fields_ = [("number", C.c_int64), ("entries", C.POINTER(NodeList))]


Node._fields_ = [("value", Value), ("format", C.c_int)]


def audio_bytes():
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as output:
        output.setparams((1, 2, 8000, 0, "NONE", "not compressed"))
        output.writeframes(b"\x01\x00" * 4000)
    return buffer.getvalue()


class MediaServer(BaseHTTPRequestHandler):
    media = audio_bytes()

    def log_message(self, *args):
        pass

    def do_GET(self):
        self.server.hits[self.path] += 1
        if self.path == "/disconnect":
            self.connection.shutdown(socket.SHUT_RDWR)
            self.close_connection = True
            return
        if self.path in ("/media.wav", "/retry.wav?second"):
            status, body, mime = 200, self.media, "audio/wav"
        elif self.path == "/bad-media":
            status, body, mime = 200, b"not a media file", "application/octet-stream"
        else:
            status, body, mime = 503, b"synthetic server error", "text/plain"
        self.send_response(status)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def run(path, server):
    lib = C.CDLL(str(path))

    def bind(name, result, *args):
        fn = getattr(lib, "mpv_" + name)
        fn.restype, fn.argtypes = result, args
        return fn

    handle, string, integer = C.c_void_p, C.c_char_p, C.c_int
    create = bind("create", handle)
    option = bind("set_option_string", integer, handle, string, string)
    initialize = bind("initialize", integer, handle)
    command = bind("command", integer, handle, C.POINTER(string))
    wait = bind("wait_event", C.POINTER(Event), handle, C.c_double)
    event_to_node = bind("event_to_node", integer, C.POINTER(Node), C.POINTER(Event))
    free_node = bind("free_node_contents", None, C.POINTER(Node))
    hook_add = bind("hook_add", integer, handle, C.c_uint64, string, integer)
    hook_continue = bind("hook_continue", integer, handle, C.c_uint64)
    set_property = bind("set_property_string", integer, handle, string, string)
    close = bind("terminate_destroy", None, handle)
    base = f"http://127.0.0.1:{server.server_port}".encode()
    core = create()
    assert core
    try:
        for key, value in [(b"config", b"no"), (b"idle", b"yes"),
                           (b"ao", b"null"), (b"vo", b"null"), (b"curl-enabled", b"yes")]:
            assert option(core, key, value) == 0, key
        assert initialize(core) == 0
        assert hook_add(core, 1, b"on_load_fail", 0) == 0
        for source, retry, subtitle, expected in [
            (b"/503", None, False, (4, -13, 503, False)),
            (b"/media.wav", None, True, (0, 0, 0, True)),
            (b"/retry.wav", b"/retry.wav?second", False, (0, 0, 0, True)),
            (b"/503", b"/disconnect", False, (4, -13, 0, False)),
            (b"/503", b"/bad-media", False, (4, -17, 0, False)),
            (b"/disconnect", None, False, (4, -13, 0, False)),
        ]:
            assert command(core, (string * 3)(b"loadfile", base + source, None)) == 0
            restarted = False
            deadline = monotonic() + 10
            while monotonic() < deadline:
                event = wait(core, 0.1)
                if event.contents.id == 25:  # MPV_EVENT_HOOK
                    hook = C.cast(event.contents.data, C.POINTER(Hook)).contents
                    if retry:
                        assert set_property(core, b"stream-open-filename", base + retry) == 0
                        retry = None
                    assert hook_continue(core, hook.id) == 0
                elif event.contents.id == 8 and subtitle:  # MPV_EVENT_FILE_LOADED
                    assert command(core, (string * 4)(b"sub-add", base + b"/optional.srt", b"auto", None)) < 0
                elif event.contents.id == 21:  # MPV_EVENT_PLAYBACK_RESTART
                    restarted = True
                elif event.contents.id == 7:  # MPV_EVENT_END_FILE
                    end = C.cast(event.contents.data, C.POINTER(EndFile)).contents
                    node = Node()
                    assert event_to_node(C.byref(node), event) == 0 and node.format == 8  # MPV_FORMAT_NODE_MAP
                    try:
                        fields = node.value.entries.contents
                        status = next((fields.values[i].value.number for i in range(fields.count)
                                       if fields.keys[i] == b"http_status" and fields.values[i].format == 4), 0)
                        observed = end.reason, end.error, status, restarted
                        assert observed == expected, (source, expected, observed)
                        print(f"{source.decode()}: reason={end.reason} mpv={end.error} HTTP={status} playback={restarted}")
                    finally:
                        free_node(C.byref(node))
                    break
            else:
                raise AssertionError(f"Timed out loading {source!r}")
        assert server.hits["/optional.srt"] == 1 and server.hits["/retry.wav?second"] >= 1, server.hits
    finally:
        close(core)


if __name__ == "__main__":
    with ThreadingHTTPServer(("127.0.0.1", 0), MediaServer) as local:
        local.hits = Counter()
        worker = Thread(target=local.serve_forever, daemon=True)
        worker.start()
        try:
            run(Path(sys.argv[1]).resolve(strict=True), local)
        finally:
            local.shutdown()
            worker.join()
