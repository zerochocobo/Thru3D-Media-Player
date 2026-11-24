"""Stage the diagnostic AAR with the pinned GeckoView runtime dependencies."""
import argparse
import hashlib
import shutil
import xml.etree.ElementTree as ET
from io import BytesIO
from pathlib import Path
from zipfile import ZipFile

VERSION = "159.0.20261022150525"
ARTIFACT = "geckoview-arm64-v8a"
GROUP = "org.mozilla.geckoview"
LIBRARY = "arm64-v8a/libxul.so"


def engine_hash(archive, prefix):
    with archive.open(prefix + "/" + LIBRARY) as lib:
        digest = hashlib.sha256()
        tail = b""
        markers = {b"Thru3DGeckoFrame", b"webrender_rgb=%s bt709=%d", b"pts_us=%"}
        while chunk := lib.read(1024 * 1024):
            digest.update(chunk)
            window = tail + chunk
            markers = {marker for marker in markers if marker not in window}
            tail = chunk[-32:]
        if markers:
            raise ValueError("ARM64 libxul lacks the paired frame probe")
        return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("aar", type=Path)
    parser.add_argument("--gradle-cache", type=Path, required=True)
    parser.add_argument("--repository", type=Path, required=True)
    parser.add_argument("--apk", type=Path)
    args = parser.parse_args()
    with ZipFile(args.aar) as aar:
        expected = engine_hash(aar, "jni")
        with ZipFile(BytesIO(aar.read("classes.jar"))) as classes:
            codec = classes.read("org/mozilla/gecko/media/Codec.class")
            surface = classes.read("org/mozilla/gecko/gfx/GeckoSurfaceTexture.class")
            if (b"Thru3DCodecFault" not in codec or b"Thru3DCodecFormat" not in codec
                    or b"getFrameProbeGeneration" not in surface):
                raise ValueError("GeckoView Java probes are missing")
    if args.apk:
        with ZipFile(args.apk) as apk:
            if engine_hash(apk, "lib") != expected:
                raise ValueError("The APK contains a different Gecko engine")
        return
    cache = args.gradle_cache / "caches/modules-2/files-2.1" / GROUP / ARTIFACT / VERSION
    pom, = cache.glob("*/*.pom")
    ns = "{http://maven.apache.org/POM/4.0.0}"
    model = ET.parse(pom)
    if model.findtext(ns + "version") != VERSION or model.findtext(ns + "artifactId") != ARTIFACT:
        raise ValueError("Unexpected base GeckoView POM")
    with args.aar.open("rb") as source:
        version = VERSION + "-probe-" + hashlib.file_digest(source, "sha256").hexdigest()[:16]
    model.find(ns + "version").text = version
    target = args.repository / GROUP.replace(".", "/") / ARTIFACT / version
    target.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(args.aar, target / f"{ARTIFACT}-{version}.aar")
    ET.register_namespace("", ns[1:-1])
    model.write(target / f"{ARTIFACT}-{version}.pom", encoding="utf-8", xml_declaration=True)
    print(f"{GROUP}:{ARTIFACT}:{version}")


if __name__ == "__main__":
    main()
