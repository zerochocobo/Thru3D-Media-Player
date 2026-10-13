"""Build the emulator-only EGL chooser overlay from the pinned Godot source.

Physical devices keep the stock exact-config choice. Only the Java chooser class changes;
every other engine class and the engine's native libraries remain byte-identical.
"""
import argparse
import hashlib
import io
import json
from pathlib import Path
import subprocess
import zipfile

CLASS = 'org/godotengine/godot/xr/ovr/OvrConfigChooser.class'

def replace_entry(original, name, data):
    result = io.BytesIO()
    with zipfile.ZipFile(io.BytesIO(original)) as src, zipfile.ZipFile(result, 'w') as dst:
        assert name in src.namelist()
        for entry in src.infolist():
            dst.writestr(entry, data if entry.filename == name else src.read(entry.filename))
    return result.getvalue()

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--workspace', type=Path, required=True)
    parser.add_argument('--tool-root', type=Path, required=True)
    args = parser.parse_args()
    root, tools = args.workspace.resolve(), args.tool_root.resolve()
    out = root / 'build/pico-emulator-egl-overlay'
    out.mkdir(parents=True, exist_ok=True)
    source = root / 'tools/environment/godot/OvrConfigChooser.java'
    classes = out / 'classes'
    classes.mkdir(exist_ok=True)
    template = tools / 'godot-templates/4.7.2.stable/android_source.zip'
    with zipfile.ZipFile(template) as stock:
        debug = stock.read('libs/debug/godot-lib.template_debug.aar')
        with zipfile.ZipFile(io.BytesIO(debug)) as aar:
            api = out / 'stock-classes.jar'
            api.write_bytes(aar.read('classes.jar'))
        subprocess.run([str(tools / 'jdk/jdk-17.0.20.1+1/bin/javac.exe'), '-source', '8', '-target', '8', '-nowarn',
            '-classpath', str(tools / 'android-sdk/platforms/android-36/android.jar') + ';' + str(api),
            '-d', str(classes), str(source)], check=True)
        replacement = (classes / CLASS).read_bytes()
        results = []
        for variant in ['debug', 'release']:
            name = f'libs/{variant}/godot-lib.template_{variant}.aar'
            base = stock.read(name)
            with zipfile.ZipFile(io.BytesIO(base)) as aar:
                original_classes = aar.read('classes.jar')
            patched_classes = replace_entry(original_classes, CLASS, replacement)
            patched = replace_entry(base, 'classes.jar', patched_classes)
            # Verify the overlay is restricted to precisely the intended Java class.
            with zipfile.ZipFile(io.BytesIO(original_classes)) as before, zipfile.ZipFile(io.BytesIO(patched_classes)) as after:
                assert before.namelist() == after.namelist()
                changed = [n for n in before.namelist() if before.read(n) != after.read(n)]
                assert changed == [CLASS], changed
            with zipfile.ZipFile(io.BytesIO(base)) as before, zipfile.ZipFile(io.BytesIO(patched)) as after:
                changed = [n for n in before.namelist() if before.read(n) != after.read(n)]
                assert changed == ['classes.jar'], changed
            target = root / 'app/godot/android/build' / name
            target.parent.mkdir(parents=True, exist_ok=True)
            temporary = target.with_suffix('.aar.pending')
            temporary.write_bytes(patched)
            temporary.replace(target)
            results.append({'variant': variant, 'stock_aar_sha256': hashlib.sha256(base).hexdigest(),
                'patched_aar_sha256': hashlib.sha256(patched).hexdigest(), 'native_engine_unchanged': True})
    report = {'engine': '4.7.2.stable.official.ed1daf0bf', 'scope': 'PICO ranchu emulator exact-config fallback only',
        'source_sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
        'class_sha256': hashlib.sha256(replacement).hexdigest(), 'archives': results}
    (out / 'verification.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(report, indent=2))

if __name__ == '__main__':
    main()
