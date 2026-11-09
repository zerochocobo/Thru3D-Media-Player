"""Reject runtime PNG pixel handoffs; explicit exports/diagnostics are reviewed exceptions.

Run during normal builds and Test-Player. Original PNG decoding is intentionally unrestricted.
New exceptions require an exact callsite and purpose here, not a whole-file exemption.
"""
from pathlib import Path
import re
import sys
from collections import Counter

ROOT = Path(__file__).resolve().parents[1]
PATTERN = re.compile(r"CompressFormat\s*\.\s*PNG|\bsave_png(?:_to_buffer)?\s*\(|\b(?:png_write\w*|stbi_write_png\w*)\s*\(")
EXCEPTIONS = {
    # Persistent, user-selected background/creation assets; not per-load bridge files.
    "app/godot/scripts/app_background.gd": ['if image.save_png(path) != OK: return {}'],
    "app/godot/scripts/puzzle/puzzle_store.gd": [
        'if image.save_png(assets.path_join("image.tmp.png"))!=OK: return {}',
        'thumbnail.save_png(assets.path_join("thumb.png"))'],
    # Explicit debug readbacks, never used as production image transport.
    "app/godot/scripts/main.gd": ['image.save_png("user://diagnostics/fisheye_readback.png")'],
    "app/godot/scripts/mpv_pixel_probe.gd": ['if image.is_empty() or image.get_size() != viewport.size or image.save_png(path) != OK:'],
    "app/godot/scripts/stream_projection_probe.gd": ['if image.is_empty() or image.save_png("user://diagnostics/" + file) != OK:'],
    "app/godot/scripts/store_capture_debug.gd": [
        'state = "captured" if picture.save_png(ROOT + "capture.png") == OK else "capture_failed"',
        'frame.save_png(ROOT + "web-frame.png")',
        'texture.get_image().save_png(ROOT+"panorama-tile.png")',
        'app.photo_menu.online.texture.get_image().save_png(ROOT+"panorama-web.png")'],
}

def violations(path, text):
    allowed = Counter(EXCEPTIONS.get(path, []))
    result = []
    # Match across whitespace too, so splitting a compressor call cannot bypass the gate.
    lines = text.splitlines()
    cleaned = "\n".join("" if line.lstrip().startswith(("#", "//", "*", "/*")) else line for line in lines)
    for match in PATTERN.finditer(cleaned):
        line_number = cleaned.count("\n", 0, match.start()) + 1
        line = lines[line_number - 1].strip()
        if allowed[line]:
            allowed[line] -= 1
        else:
            result.append(f"{path}:{line_number}: PNG handoff requires review; use RawPhoto/BitmapTransfer/raw_image.gd")
    return result

def scan():
    failures = []
    roots = [ROOT / 'app/godot/scripts', ROOT / 'native']
    roots += list((ROOT / 'android').glob('*/src/main'))
    for folder in roots:
        if 'fixture' in str(folder):  # standalone test APKs, never production sources
            continue
        for path in folder.rglob('*'):
            if path.suffix not in {'.gd', '.kt', '.java', '.cpp', '.cc', '.c', '.h', '.hpp'}:
                continue
            failures += violations(path.relative_to(ROOT).as_posix(), path.read_text(encoding='utf-8-sig'))
    return failures

def self_test():
    assert violations('new.kt', 'bitmap.compress(Bitmap.CompressFormat.\n PNG,100,out)')
    assert violations('new.gd', 'image.save_png_to_buffer()')
    assert violations('new.cpp', 'stbi_write_png(path, w, h, 4, pixels, stride);')
    assert not violations('new.gd', 'image.load_png_from_buffer(bytes)')
    path = 'app/godot/scripts/app_background.gd'
    allowed = EXCEPTIONS[path][0]
    assert not violations(path, allowed)
    assert violations(path, allowed + '\n' + allowed)
    assert violations(path, allowed + '\nimage.save_png("preview.png")')

if __name__ == '__main__':
    self_test()
    failures = scan()
    print('\n'.join(failures) if failures else 'Image transfer guard: passed (including mutation checks)')
    sys.exit(bool(failures))
