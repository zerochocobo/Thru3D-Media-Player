"""Exercise the actual pinned encrypted TCP mirror transport with synthetic H264 packets."""
import argparse
import hashlib
from pathlib import Path
import socket
import struct
import subprocess
import unittest
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

SERVER = None

class MirrorTransportTest(unittest.TestCase):
    def setUp(self):
        self.process = subprocess.Popen([SERVER, "--mirror"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, text=True)
        port = self.process.stdout.readline().strip()
        if not port:
            output, errors = self.process.communicate(timeout=5)
            raise RuntimeError("Mirror fixture failed: " + errors)
        self.socket = socket.create_connection(("127.0.0.1", int(port)), timeout=5)
        seed = bytes(range(16))
        key = hashlib.sha512(b"AirPlayStreamKey7" + seed).digest()[:16]
        iv = hashlib.sha512(b"AirPlayStreamIV7" + seed).digest()[:16]
        self.encrypt = Cipher(algorithms.AES(key), modes.CTR(iv)).encryptor()

    def tearDown(self):
        self.socket.close()
        output, errors = self.process.communicate("q\n", timeout=10)
        self.assertEqual(self.process.returncode, 0, errors)

    def send(self, kind, stamp, payload):
        header = bytearray(128)
        struct.pack_into("<I", header, 0, len(payload)); header[4] = kind
        header[5] = 0x10 if kind == 0 else 0
        header[6:8] = b"\x16\x01" if kind == 1 else b"\0\0"
        struct.pack_into("<Q", header, 8, stamp)
        for offset, value in [(16, 1440), (20, 1920), (40, 1440), (44, 1920), (56, 1440), (60, 1920)]:
            struct.pack_into("<f", header, offset, value)
        self.socket.sendall(header + payload)

    def configure(self, stamp):
        sps, pps = b"\x67\x42\x00\x1f\x80", b"\x68\xce\x06\xe2"
        avcc = b"\x01\x42\x00\x1f\xff\xe1" + struct.pack(">H", len(sps)) + sps
        avcc += b"\x01" + struct.pack(">H", len(pps)) + pps
        self.send(1, stamp, avcc)

    def picture(self, stamp, nal=5, corrupt=False):
        payload = struct.pack(">I", 12 if not corrupt else 1000) + bytes([0x60 | nal]) + b"\x80" * 11
        self.send(0, stamp, self.encrypt.update(payload))
        row = self.process.stdout.readline().split()
        self.assertEqual(row[0], "VIDEO")
        return tuple(map(int, row[1:]))

    def test_matching_timestamp_delivers_configuration_and_first_keyframe(self):
        self.configure(100 << 32)
        self.assertEqual(self.picture(100 << 32), (0, 1, 1, 1))
        self.assertEqual(self.picture((100 << 32) + 1, nal=1), (0, 0, 0, 0))

    def test_configuration_survives_a_different_first_frame_timestamp(self):
        self.configure(100 << 32)
        self.assertEqual(self.picture((100 << 32) + 143165576), (0, 1, 1, 1))

    def test_new_configuration_is_delivered_after_a_timestamp_change(self):
        self.configure(100 << 32); self.picture(100 << 32)
        self.configure(102 << 32)
        self.assertEqual(self.picture((102 << 32) + 1), (0, 1, 1, 1))

    def test_malformed_encrypted_nal_is_still_marked_invalid(self):
        self.configure(100 << 32)
        self.assertEqual(self.picture(100 << 32, corrupt=True)[0], 1)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(); parser.add_argument("--server", required=True)
    args, extra = parser.parse_known_args(); SERVER = str(Path(args.server).resolve())
    unittest.main(argv=[__file__] + extra, verbosity=2)
