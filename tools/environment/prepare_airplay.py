"""Restore exact, hash-verified AirPlay build inputs. No APK or device operation."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / "build" / "airplay"

def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()

def patched_files_valid(destination, source):
    return all((destination / name).is_file() and digest(destination / name) == expected
               for name, expected in source.get("patched_files", {}).items())

def main():
    manifest = json.loads((ROOT / "third_party/airplay/sources.json").read_text("utf-8"))
    for source in manifest["sources"]:
        archive = BUILD / "sources" / (source["root"] + ".tar.gz")
        archive.parent.mkdir(parents=True, exist_ok=True)
        if archive.exists():
            if digest(archive) != source["sha256"]:
                raise RuntimeError(f"AirPlay source digest differs: {source['id']}")
        else:
            download = ROOT / "tmp" / "airplay-downloads" / archive.name
            download.parent.mkdir(parents=True, exist_ok=True)
            with urllib.request.urlopen(source["url"], timeout=120) as remote, download.open("wb") as out:
                shutil.copyfileobj(remote, out)
            if digest(download) != source["sha256"]:
                raise RuntimeError(f"AirPlay download digest differs: {source['id']}")
            shutil.copyfile(download, archive)
        destination = BUILD / ("sources" if source["id"] == "openssl" else "deps") / (source["root"] if source["id"] == "openssl" else source["id"])
        patches = [ROOT / "native/airplay/patches" / name for name in source.get("patches", [])]
        expected = source["sha256"] + "".join(":" + digest(patch) for patch in patches)
        marker = destination / ".thru3d-source"
        if marker.is_file() and marker.read_text("ascii") == expected and patched_files_valid(destination, source):
            continue
        extraction = BUILD / "extract" / source["sha256"]
        extraction.mkdir(parents=True, exist_ok=True)
        with tarfile.open(archive) as tar:
            tar.extractall(extraction, filter="data")
        # These are reproducible sources under build/, never credentials or a user backup.
        shutil.copytree(extraction / source["root"], destination, dirs_exist_ok=True)
        if source["id"] == "uxplay":
            for name in source.get("patched_files", {}):
                target = destination / name
                target.write_bytes(target.read_bytes().replace(b"\r\n", b"\n"))
            # git apply in a repository subdirectory silently skips paths outside that prefix.
            # Apply from the workspace root with an explicit destination, then verify its output.
            for patch in patches:
                subprocess.run(["git", "apply", "--whitespace=nowarn",
                                "--directory=" + destination.relative_to(ROOT).as_posix(), str(patch)],
                               cwd=ROOT, check=True)
        if not patched_files_valid(destination, source):
            raise RuntimeError(f"AirPlay patched source digest differs: {source['id']}")
        marker.write_text(expected, "ascii")
    print("AirPlay source digests verified")

if __name__ == "__main__":
    main()
