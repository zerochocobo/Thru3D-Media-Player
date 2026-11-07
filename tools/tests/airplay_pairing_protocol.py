"""Run real RTSP/SRP pairing requests against the pinned host protocol server.

Usage (Linux/WSL): python3 tools/tests/airplay_pairing_protocol.py --server build/airplay/host-pairing/airplay_pairing_server
The host uses system OpenSSL 3 and Python cryptography; this does not replace Android/iPhone acceptance.
"""
import argparse
import hashlib
from pathlib import Path
import plistlib
import re
import secrets
import socket
import subprocess
import tempfile
import unittest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ed25519, x25519
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

# RFC 5054 2048-bit group, as used by pair-setup-pin (SHA-1, Apple session key).
N = int(
    "AC6BDB41324A9A9BF166DE5E1389582FAF72B6651987EE07FC3192943DB56050A37329CBB4"
    "A099ED8193E0757767A13DD52312AB4B03310DCD7F48A9DA04FD50E8083969EDB767B0CF60"
    "95179A163AB3661A05FBD5FAAAE82918A9962F0B93B855F97993EC975EEAA80D740ADBF4FF"
    "747359D041D5C33EA71D281E446B14773BCA97B43A23FB801676BD207A436C6481F1D2B907"
    "8717461A5B9D32E688F87748544523B524B0D57D5EA77A2775D2ECFA032CFBDBF52FB37861"
    "60279004E57AE6AF874E7303CE53299CCC041C7BC308D82A5698F3A8D0C38271AE35F8E9DB"
    "FBB694B5C803D89F7AE435DE236D525F54759B65E372FCD68EF20FA7111F9E4AFF73", 16)
G = 2
SERVER = None
ROOT = Path(__file__).resolve().parents[2]


def integer(value, padded=False):
    return value.to_bytes(256 if padded else max(1, (value.bit_length() + 7) // 8), "big")


def sha(*values):
    return hashlib.sha1(b"".join(values)).digest()


class ProtocolServerTest(unittest.TestCase):
    require_pin = False
    require_password = False

    def setUp(self):
        output = ROOT / "build/airplay/host-pairing"
        output.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=output)
        self.errors = open(Path(self.temp.name) / "protocol.log", "w+")
        self.process = subprocess.Popen([SERVER, str(Path(self.temp.name) / "synthetic.key")] +
                                        (["--password"] if self.require_password else ["--pin"] if self.require_pin else []),
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.errors, text=True)
        self.port = port = int(self.process.stdout.readline().strip())
        self.advertisement = dict(field.split("=", 1) for field in self.process.stdout.readline().split())
        self.socket = socket.create_connection(("127.0.0.1", port), timeout=5)
        self.stream = self.socket.makefile("rb")
        self.sequence = 0

    def tearDown(self):
        self.stream.close()
        self.socket.close()
        if self.process.poll() is None:
            self.process.communicate("q\n", timeout=10)
        status = self.process.returncode
        self.errors.seek(0)
        errors = self.errors.read()
        self.errors.close()
        self.temp.cleanup()
        self.assertEqual(status, 0, errors)

    def request(self, fields, method="POST", path="/pair-setup-pin", extra_headers=None):
        self.sequence += 1
        raw = isinstance(fields, bytes)
        payload = fields if raw else plistlib.dumps(fields, fmt=plistlib.FMT_BINARY) if fields is not None else b""
        content_type = "application/octet-stream" if raw else "application/x-apple-binary-plist"
        header = (f"{method} {path} RTSP/1.0\r\n"
                  f"CSeq: {self.sequence}\r\nUser-Agent: AirPlay/320.20\r\n"
                  + (f"Content-Type: {content_type}\r\n" if fields is not None else "") +
                  "".join(f"{key}: {value}\r\n" for key, value in (extra_headers or {}).items()) +
                  f"Content-Length: {len(payload)}\r\n\r\n").encode("ascii")
        self.socket.sendall(header + payload)
        status_line = self.stream.readline()
        if not status_line:
            raise EOFError("Server closed the connection")
        status = int(status_line.split()[1])
        headers = {}
        while line := self.stream.readline().strip():
            key, value = line.split(b":", 1)
            headers[key.lower()] = value.strip()
        response = self.stream.read(int(headers.get(b"content-length", b"0")))
        self.headers = headers
        return status, plistlib.loads(response) if b"plist" in headers.get(b"content-type", b"") else response or None

    def proof(self, password):
        user = "ProtocolTest"
        status, challenge = self.request({"method": "pin", "user": user})
        self.assertEqual(status, 200)
        salt, public_b = challenge["salt"], int.from_bytes(challenge["pk"], "big")
        secret_a = secrets.randbits(256)
        public_a = pow(G, secret_a, N)
        multiplier = int.from_bytes(sha(integer(N, True), integer(G, True)), "big")
        scrambling = int.from_bytes(sha(integer(public_a, True), integer(public_b, True)), "big")
        x = int.from_bytes(sha(integer(int.from_bytes(salt, "big")), sha(user.encode(), b":", password.encode())), "big")
        shared = pow((public_b - multiplier * pow(G, x, N)) % N, secret_a + scrambling * x, N)
        key = sha(integer(shared), b"\0\0\0\0") + sha(integer(shared), b"\0\0\0\1")
        group_hash = bytes(a ^ b for a, b in zip(sha(integer(N)), sha(integer(G))))
        proof = sha(group_hash, sha(user.encode()), integer(int.from_bytes(salt, "big")),
                    integer(public_a), integer(public_b), key)
        return integer(public_a), proof, sha(integer(public_a), proof, key)

class PairingProtocolTest(ProtocolServerTest):
    require_pin = True

    def test_correct_pin_and_server_proof(self):
        public, proof, expected_server = self.proof("4321")
        self.assertEqual(len(proof), 20)
        status, response = self.request({"pk": public, "proof": proof})
        self.assertEqual(status, 200)
        self.assertEqual(response["proof"], expected_server)

    def test_mirror_profile_advertises_audio_and_portrait_resolution(self):
        status, response = self.request(None, method="GET", path="/info")
        self.assertEqual(status, 200)
        self.assertTrue(response["features"] & (1 << 9), "iOS requires audio support to keep its mirror session alive")
        self.assertFalse(response["features"] & (1 << 42), "HEVC is not supported")
        self.assertFalse(response["features"] & 1, "HLS video casting is not supported")
        display = response["displays"][0]
        self.assertEqual((display["widthPixels"], display["heightPixels"]), (1920, 1920))
        self.assertEqual(display["maxFPS"], 30)

    def test_wrong_pin_then_retry(self):
        public, proof, _ = self.proof("1234")
        self.assertEqual(self.request({"pk": public, "proof": proof})[0], 470)
        public, proof, expected_server = self.proof("4321")
        status, response = self.request({"pk": public, "proof": proof})
        self.assertEqual(status, 200)
        self.assertEqual(response["proof"], expected_server)

    def test_malformed_lengths_then_retry(self):
        for length in (0, 19, 21, 64, 65):
            with self.subTest(length=length):
                public, proof, _ = self.proof("4321")
                malformed = (proof + b"x" * 65)[:length]
                self.assertEqual(self.request({"pk": public, "proof": malformed})[0], 470)
        public, proof, expected_server = self.proof("4321")
        status, response = self.request({"pk": public, "proof": proof})
        self.assertEqual(status, 200)
        self.assertEqual(response["proof"], expected_server)


class NoPinProtocolTest(ProtocolServerTest):
    def test_open_mode_does_not_challenge_media_access(self):
        self.assertEqual(self.request(PasswordProtocolTest.setup, method="SETUP", path="/stream")[0], 200)

    def test_both_services_advertise_no_password(self):
        self.assertEqual(self.advertisement["airplay_pw"], "false")
        self.assertEqual(self.advertisement["raop_pw"], "false")
        self.assertEqual(int(self.advertisement["raop_sf"], 16) & 8, 0, "PIN-required flag is absent")

    def handshake(self):
        client_ed = ed25519.Ed25519PrivateKey.generate()
        client_x = x25519.X25519PrivateKey.generate()
        def public(key):
            return key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
        client_ed_public, client_x_public = public(client_ed), public(client_x)
        status, server_ed = self.request(client_ed_public, path="/pair-setup")
        self.assertEqual(status, 200)
        self.assertEqual(len(server_ed), 32)
        status, exchange = self.request(b"\x01\0\0\0" + client_x_public + client_ed_public, path="/pair-verify")
        self.assertEqual(status, 200)
        self.assertEqual(len(exchange), 96, "A new client can complete key exchange without PIN registration")
        server_x = exchange[:32]
        shared = client_x.exchange(x25519.X25519PublicKey.from_public_bytes(server_x))
        key = hashlib.sha512(b"Pair-Verify-AES-Key" + shared).digest()[:16]
        iv = hashlib.sha512(b"Pair-Verify-AES-IV" + shared).digest()[:16]
        cipher = Cipher(algorithms.AES(key), modes.CTR(iv)).encryptor()
        server_signature = cipher.update(exchange[32:])
        ed25519.Ed25519PublicKey.from_public_bytes(server_ed).verify(server_signature, server_x + client_x_public)
        return cipher.update(client_ed.sign(client_x_public + server_x))

    def test_direct_pairing_keeps_authenticated_encrypted_key_exchange(self):
        proof = self.handshake()
        self.assertEqual(self.request(b"\0\0\0\0" + proof, path="/pair-verify"), (200, None))
        self.assertEqual(self.request(None, method="OPTIONS", path="*")[0], 200)

    def test_direct_pairing_still_rejects_a_forged_signature(self):
        proof = bytearray(self.handshake()); proof[0] ^= 1
        self.request(b"\0\0\0\0" + proof, path="/pair-verify")
        with self.assertRaises((EOFError, ConnectionResetError, BrokenPipeError)):
            self.request(None, method="OPTIONS", path="*")


class PasswordProtocolTest(ProtocolServerTest):
    require_password = True
    setup = {"deviceID": "02:00:00:00:00:02", "model": "iPad", "name": "ProtocolTest",
             "eiv": bytes(16), "ekey": bytes(72)}

    def challenge(self):
        self.assertEqual(self.request(self.setup, method="SETUP", path="/stream")[0], 401)
        prefix, code = self.process.stdout.readline().strip().split()
        self.assertEqual(prefix, "PIN")
        self.assertRegex(code, r"^\d{4}$")
        return code, self.nonce()

    def nonce(self):
        return re.search(r'nonce="([0-9a-fA-F]{32})"', self.headers[b"www-authenticate"].decode()).group(1)

    def authenticate(self, code, nonce):
        def md5(value):
            return hashlib.md5(value.encode()).hexdigest()
        response = md5(md5("AirPlay:raop:" + code) + ":" + nonce + ":" + md5("SETUP:/stream"))
        header = f'Digest username="AirPlay", realm="raop", nonce="{nonce}", uri="/stream", response="{response}"'
        return self.request(self.setup, method="SETUP", path="/stream", extra_headers={"Authorization": header})[0]

    def test_password_mode_advertises_both_services(self):
        self.assertEqual(self.advertisement["airplay_pw"], "true")
        self.assertEqual(self.advertisement["raop_pw"], "true")
        self.assertEqual(int(self.advertisement["raop_sf"], 16), 0x84)
        self.challenge()

    def test_wrong_code_rejected_then_correct_code_authorizes_only_this_connection(self):
        code, nonce = self.challenge()
        wrong = "0000" if code != "0000" else "0001"
        self.assertEqual(self.authenticate(wrong, nonce), 401)
        self.assertEqual(self.authenticate(code, self.nonce()), 200)
        self.assertEqual(self.request(self.setup, method="SETUP", path="/stream")[0], 200)

    def test_a_new_connection_requires_a_code_again(self):
        code, nonce = self.challenge()
        self.assertEqual(self.authenticate(code, nonce), 200)
        self.stream.close(); self.socket.close()
        self.socket = socket.create_connection(("127.0.0.1", self.port), timeout=5)
        self.stream = self.socket.makefile("rb")
        self.challenge()

    def test_a_previous_nonce_cannot_authorize_a_later_challenge(self):
        code, nonce = self.challenge()
        wrong = "0000" if code != "0000" else "0001"
        self.assertEqual(self.authenticate(wrong, nonce), 401)
        self.assertEqual(self.authenticate(code, nonce), 401)
        self.assertEqual(self.authenticate(code, self.nonce()), 200)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--server", required=True)
    arguments, extra = parser.parse_known_args()
    SERVER = str(Path(arguments.server).resolve())
    unittest.main(argv=[__file__] + extra, verbosity=2)
