"""Exercise patch preparation inside a real Git worktree, without downloads or an APK."""
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("prepare_airplay", ROOT / "tools/environment/prepare_airplay.py")
PREPARE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PREPARE)
SOURCE = json.loads((ROOT / "third_party/airplay/sources.json").read_text("utf-8"))["sources"][0]
PATCHES = ["native/airplay/patches/" + name for name in SOURCE["patches"]]


class AirplayPreparationTest(unittest.TestCase):
    def setUp(self):
        scratch = ROOT / "tmp/airplay-prepare-tests"
        scratch.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=scratch)
        self.root = Path(self.temp.name)
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        self.build = self.root / "build/airplay"
        self.archive = self.build / "sources" / (SOURCE["root"] + ".tar.gz")
        self.archive.parent.mkdir(parents=True)
        shutil.copyfile(ROOT / "build/airplay/sources" / self.archive.name, self.archive)
        manifest = self.root / "third_party/airplay/sources.json"
        manifest.parent.mkdir(parents=True)
        manifest.write_text(json.dumps({"sources": [SOURCE]}), encoding="utf-8")
        for name in PATCHES:
            patch = self.root / name
            patch.parent.mkdir(parents=True, exist_ok=True)
            patch.write_bytes((ROOT / name).read_bytes().replace(b"\r\n", b"\n"))
        self.old_root, self.old_build = PREPARE.ROOT, PREPARE.BUILD
        PREPARE.ROOT, PREPARE.BUILD = self.root, self.build
        self.destination = self.build / "deps/uxplay"
        self.header = self.destination / "lib/raop_handlers.h"

    def tearDown(self):
        PREPARE.ROOT, PREPARE.BUILD = self.old_root, self.old_build
        self.temp.cleanup()

    def assert_patched(self):
        for name, expected in SOURCE["patched_files"].items():
            self.assertEqual(PREPARE.digest(self.destination / name), expected)

    def test_patch_applied_in_nested_worktree(self):
        PREPARE.main()
        self.assert_patched()
        self.assertFalse((self.root / "lib/raop_handlers.h").exists())

    def test_verified_cache_preserves_source(self):
        PREPARE.main()
        previous = self.header.stat().st_mtime_ns
        PREPARE.main()
        self.assert_patched()
        self.assertEqual(previous, self.header.stat().st_mtime_ns)

    def test_stale_success_marker_repairs_unpatched_source(self):
        PREPARE.main()
        # Reproduce the old git-apply no-op: marker claims success, source remains unpatched.
        extracted = self.build / "extract" / SOURCE["sha256"] / SOURCE["root"] / "lib/raop_handlers.h"
        self.header.write_bytes(extracted.read_bytes().replace(b"\r\n", b"\n"))
        PREPARE.main()
        self.assert_patched()

    def test_unexpected_patch_output_is_rejected(self):
        patch = self.root / PATCHES[0]
        patch.write_bytes(patch.read_bytes().replace(b"proof[20]", b"proof[21]"))
        with self.assertRaisesRegex(RuntimeError, "patched source digest differs"):
            PREPARE.main()
        self.assertFalse((self.destination / ".thru3d-source").exists())

    def test_stale_success_marker_repairs_unpatched_mirror_transport(self):
        PREPARE.main()
        name = "lib/raop_rtp_mirror.c"
        original = self.build / "extract" / SOURCE["sha256"] / SOURCE["root"] / name
        (self.destination / name).write_bytes(original.read_bytes().replace(b"\r\n", b"\n"))
        PREPARE.main()
        self.assert_patched()


if __name__ == "__main__":
    unittest.main()
