"""Persistently overlay the narrow Godot launch guard after template installation."""
from __future__ import annotations

import argparse
from pathlib import Path
import re

MARKER = "// Thru3D external launch controls are filtered before GodotActivity."
CREATE = "setIntent(GodotLaunchIntentGuard.sanitize(this, getIntent()));"
NEW_INTENT = "super.onNewIntent(GodotLaunchIntentGuard.sanitize(this, intent));"


def patched_host(text: str) -> str:
    if MARKER in text:
        if text.count(MARKER) != 1 or text.count(CREATE) != 1 or text.count(NEW_INTENT) != 1:
            raise ValueError("Godot host launch guard is incomplete")
        return text
    if re.search(r"\bonNewIntent\s*\(", text):
        raise ValueError("Godot host already overrides onNewIntent; review before patching")
    anchor = re.compile(r"(?m)^([ \t]*)public void onCreate\(Bundle savedInstanceState\) \{")
    if len(anchor.findall(text)) != 1 or "public class GodotApp extends GodotActivity" not in text:
        raise ValueError("Godot host template differs from the reviewed 4.7.2 source")
    text = anchor.sub(lambda m: m.group(0) + "\n" + m.group(1) + "\t" + MARKER + "\n" + m.group(1) + "\t" + CREATE, text)
    end = text.rfind("\n}")
    if end < 0:
        raise ValueError("Godot host class ending is missing")
    override = ("\n\t@Override\n\tprotected void onNewIntent(android.content.Intent intent) {\n"
                "\t\t" + NEW_INTENT + "\n\t}\n")
    return text[:end] + override + text[end:]


def prepare(workspace: Path) -> bool:
    java_dir = workspace / "app/godot/android/build/src/main/java/com/godot/game"
    host = java_dir / "GodotApp.java"
    helper = workspace / "android/host/GodotLaunchIntentGuard.java"
    original = host.read_text(encoding="utf-8")
    replacement = patched_host(original)
    payload = helper.read_bytes()  # Check every required input before modifying the template.
    target = java_dir / helper.name
    changed = original != replacement or not target.exists() or target.read_bytes() != payload
    if original != replacement:
        host.write_text(replacement, encoding="utf-8", newline="\n")
    if not target.exists() or target.read_bytes() != payload:
        target.write_bytes(payload)
    return changed


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace", type=Path, required=True)
    args = parser.parse_args()
    print("Android host launch guard: " + ("updated" if prepare(args.workspace.resolve()) else "unchanged"))
