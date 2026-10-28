"""Verify actual native ZIP methods, including empty files, rather than lengths."""
import argparse
import json
import zipfile

parser = argparse.ArgumentParser()
parser.add_argument("apk")
parser.add_argument("mode", choices=("stored", "deflate"))
args = parser.parse_args()
expected = zipfile.ZIP_STORED if args.mode == "stored" else zipfile.ZIP_DEFLATED
with zipfile.ZipFile(args.apk) as archive:
    libraries = [entry for entry in archive.infolist()
                 if entry.filename.startswith("lib/") and entry.filename.endswith(".so")]
    if not libraries:
        raise SystemExit("APK contains no native libraries")
    wrong = [entry.filename for entry in libraries if entry.compress_type != expected]
    if wrong:
        raise SystemExit("Unexpected native compression: " + ", ".join(wrong))
    print(json.dumps({"native_libraries": len(libraries), "compression": args.mode, "status": "passed"}))
