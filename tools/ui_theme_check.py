"""Capture production UI fixtures and compare their decoded RGBA pixels exactly.

Only temporary fixture copies get deterministic clock/animation/cache samples and
redirected output. Production files are never patched by this runner. The source
revision used as the baseline must precede theme changes.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from collections import Counter
import io
import zipfile

from PIL import Image, ImageChops

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "app/godot"
OUTPUT = ROOT / "build/output/ui-themes"
FIXTURES = {
    "library": ("render_library_menu", "QUEST_LIBRARY_PREVIEW_DIR"),
    "player": ("render_player_menu", "QUEST_PLAYER_MENU_PREVIEW_DIR"),
    "browser-home": ("render_web_video_home", "WEB_VIDEO_PREVIEW"),
    "browser-panel": ("render_web_browser_panel", "WEB_VIDEO_PREVIEW"),
    "accounts": ("render_account_management", "QUEST_ACCOUNT_PREVIEW_DIR"),
    "music": ("render_background_audio", ""),
    "scenery": ("render_scenery_menu", ""),
    "keyboard": ("render_chinese_keyboard", ""),
    "controls": ("render_controls_page", "CONTROLS_UI_OUTPUT"),
    "typography": ("render_select_typography", "SELECT_UI_OUTPUT"),
    "photos": ("render_photos", ""),
    "pip": ("render_video_pip_ui", ""),
    "states": ("render_ui_theme_states", "UI_THEME_CAPTURE_DIR"),
    "seek": ("render_seek_feedback", "THRU3D_TEST_OUTPUT"),
    "immersive": ("render_immersive_adjustments", ""),
    "status": ("render_playback_status_overlay", "THRU3D_TEST_OUTPUT"),
    "disc": ("render_disc_menu_bar", ""),
    "puzzle": ("render_puzzle_flow", ""),
    "media-server": ("render_media_server_browser", "QUEST_SERVER_PREVIEW_DIR"),
    "photo-adjustments": ("render_photo_adjustments", ""),
    "switch": ("render_ui_theme_switch", "UI_THEME_CAPTURE_DIR"),
    "readability": ("render_ui_theme_readability", "UI_THEME_CAPTURE_DIR"),
    "custom": ("render_custom_theme", "UI_THEME_CAPTURE_DIR"),
    "footer-brand": ("render_footer_brand", "UI_THEME_CAPTURE_DIR"),
}

# These pixel-oracle failures reproduce before any production theme edits.
# Capture them as known failures, never call that fixture's assertions passed.
# A changed message/count, parse error or any additional error still fails.
KNOWN_BASELINE_ERRORS = {"controls": Counter({
    "ERROR: Ray pixels remain visible over the dialog": 8,
    "ERROR: Live grip line pixels track the current hand origin": 3,
})}


def capture(stage: str, theme: str, godot: str, names: list[str], source_ref: str = "", update: bool = False) -> None:
    run_root = OUTPUT / stage
    run_root.mkdir(parents=True, exist_ok=True)
    temp = ROOT / "tmp/ui-themes"
    temp.mkdir(parents=True, exist_ok=True)
    manifest = {"theme": theme, "stage": stage, "fixtures": {}, "pixels": {}}
    if update:
        manifest = json.loads((run_root / "capture.json").read_text(encoding="utf-8"))
        if manifest["theme"] != theme or manifest["source_ref"] != (source_ref or "working-tree"):
            raise ValueError("Cannot combine captures from different themes or source revisions")
    manifest["git_head"] = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    manifest["source_ref"] = source_ref or "working-tree"
    source_root = OUTPUT / "original-source"
    reference_pack = OUTPUT / "original-source.pck"
    if source_ref:
        archive = subprocess.check_output(["git", "archive", "--format=zip", source_ref,
                                           "app/godot/scripts", "app/godot/shaders", "app/godot/tests"], cwd=ROOT)
        with zipfile.ZipFile(io.BytesIO(archive)) as bundle:
            for entry in bundle.namelist():
                if not entry.endswith((".gd", ".gdshader")):
                    continue
                relative = Path(entry).relative_to("app/godot")
                target = source_root / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(bundle.read(entry))
        pack_files = [{"resource": "res://" + str(path.relative_to(source_root)).replace("\\", "/"),
                       "source": str(path)} for path in source_root.rglob("*") if path.is_file()]
        pack_manifest = temp / "reference-pack.json"
        pack_manifest.write_text(json.dumps(pack_files), encoding="utf-8")
        packer = temp / "pack_reference.gd"
        packer.write_text('''extends SceneTree
func _initialize() -> void:
	var packer := PCKPacker.new()
	if packer.pck_start(OS.get_environment("UI_THEME_REFERENCE_PACK")) != OK: quit(1); return
	var entries: Array = JSON.parse_string(FileAccess.get_file_as_string(OS.get_environment("UI_THEME_REFERENCE_FILES")))
	for entry in entries:
		if packer.add_file(entry.resource, entry.source) != OK: quit(1); return
	quit(0 if packer.flush() == OK else 1)
''', encoding="utf-8")
        pack_env = os.environ.copy()
        pack_env.update(UI_THEME_REFERENCE_PACK=str(reference_pack), UI_THEME_REFERENCE_FILES=str(pack_manifest))
        packed = subprocess.run([godot, "--headless", "--xr-mode", "off", "--path", str(PROJECT), "--script", str(packer)],
                                cwd=ROOT, env=pack_env, capture_output=True, text=True, timeout=60,
                                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        if packed.returncode or "ERROR:" in packed.stdout + packed.stderr:
            raise RuntimeError("Cannot build historical source pack: " + packed.stdout + packed.stderr)
    for name in names:
        script, output_env = FIXTURES[name]
        source_path = PROJECT / "tests" / (script + ".gd")
        source = source_path.read_text(encoding="utf-8-sig")
        # Puzzle history fixtures use wall-clock sample dates, unrelated to UI style.
        source = source.replace("Time.get_unix_time_from_system()", "1793836800.0")
        destination = run_root / name
        destination.mkdir(parents=True, exist_ok=True)
        manifest["fixtures"][name] = {
            "source": str(source_path.relative_to(ROOT)),
            "sha256": hashlib.sha256(source.encode()).hexdigest(),
        }
        # These are output folder expressions in the selected fixtures. Never
        # redirect media resources or user:// settings into the test destination.
        source = re.sub(
            r'ProjectSettings.globalize_path\("res://../../build/output/[^"\n]+"\)',
            'OS.get_environment("UI_THEME_CAPTURE_DIR")', source)
        source = re.sub(
            r"func _initialize\(\) -> void:[ \t]*",
            "func _initialize() -> void:\n\t_ui_theme_fixture_init()\n\t", source, count=1)
        source += '''

func _ui_theme_fixture_init() -> void:
	node_added.connect(_ui_theme_pin_clock)
	process_frame.connect(_ui_theme_before_process)
	RenderingServer.frame_pre_draw.connect(_ui_theme_freeze_hints)
	if ResourceLoader.exists("res://scripts/ui_theme.gd"):
		var palette = load("res://scripts/ui_theme.gd")
		palette.use(OS.get_environment("UI_THEME_CAPTURE"))

func _ui_theme_pin_clock(node: Node) -> void:
	if node.get_script() == preload("res://scripts/device_status.gd"):
		node.clock_provider = func(): return {"hour": 10, "minute": 8}
	if node.has_method("_animate_settings_scroll_hint"):
		_ui_theme_animated.append(weakref(node))
	# The brand's adjacent antialiased labels touch. Pin their transparent draw
	# order in both revisions, rather than let unrelated resource IDs break ties.
	if node is Label3D and node.text == ".com": node.sorting_offset = 0.0001
	if node is MeshInstance3D and node.material_override is ShaderMaterial:
		var material: ShaderMaterial = node.material_override
		if material.shader.code.contains("TIME * 5.0"):
			material.shader = material.shader.duplicate()
			material.shader.code = material.shader.code.replace("TIME * 5.0", "0.25 * 5.0")

var _ui_theme_animated: Array[WeakRef] = []
func _ui_theme_before_process() -> void:
	for reference in _ui_theme_animated:
		var menu = reference.get_ref()
		if menu == null: continue
		# Let normal processing run, but give the scroll cue the same animation phase.
		menu._settings_scroll_hint_time = 0.25 - menu.get_process_delta_time()
		# Cache usage is asynchronous user data, not a style. Set a fixed fixture
		# result before its normal poll can race the pointer/viewport capture.
		if menu._cache_task >= 0:
			WorkerThreadPool.wait_for_task_completion(menu._cache_task)
			menu._cache_task = -1
			menu._cache_usage = Vector2i(2, 131072)
			var hovered: Dictionary = menu._hover.duplicate()
			menu.refresh(); menu._hover = hovered; menu._update_highlights()

func _ui_theme_freeze_hints() -> void:
	for reference in _ui_theme_animated:
		var menu = reference.get_ref()
		if menu != null:
			menu._settings_scroll_hint_time = 0.25
			menu._animate_settings_scroll_hint(0.0)
'''
        wrapper = temp / (script + ".gd")
        wrapper.write_text(source, encoding="utf-8")
        env = os.environ.copy()
        env.update({"UI_THEME_CAPTURE_DIR": str(destination),
                    "UI_THEME_CAPTURE": theme, "QUEST_UI_LANGUAGE": "en"})
        if output_env:
            env[output_env] = str(destination)
        for key in ["QUEST_ABOUT_PREVIEW_ONLY", "QUEST_MODELS_PREVIEW_ONLY",
                    "QUEST_STORAGE_PREVIEW_ONLY", "WEB_VIDEO_PREVIEW_CHANNEL"]:
            env.pop(key, None)
        entry_script = wrapper
        if source_ref:
            # Mount historical scripts before parsing/preloading any fixture.
            # The virtual pack only affects this test process, never workspace files.
            entry_script = temp / "historical_boot.gd"
            entry_script.write_text('''extends SceneTree
func _initialize() -> void:
	if not ProjectSettings.load_resource_pack(OS.get_environment("UI_THEME_REFERENCE_PACK"), true): quit(1); return
	set_script(load(OS.get_environment("UI_THEME_FIXTURE_SCRIPT")))
	call("_initialize")
''', encoding="utf-8")
            env.update(UI_THEME_REFERENCE_PACK=str(reference_pack), UI_THEME_FIXTURE_SCRIPT=str(wrapper))
        print(f"{stage}: {name}", flush=True)
        completed = subprocess.run(
            [godot, "--xr-mode", "off", "--rendering-method", "gl_compatibility",
             "--rendering-driver", "opengl3", "--path", str(PROJECT),
             "--quit-after", "3000", "--script", str(entry_script)],
            cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, encoding="utf-8", errors="replace", timeout=240,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        (destination / "render.log").write_text(completed.stdout, encoding="utf-8")
        errors = re.findall(r"(?m)^(?:SCRIPT ERROR:|SHADER ERROR:|ERROR:).*", completed.stdout)
        allowed = KNOWN_BASELINE_ERRORS.get(name, Counter())
        known = bool(errors) and (Counter(errors) == allowed if theme == "default" else Counter(errors) <= allowed)
        manifest["fixtures"][name]["preexisting_assertion_failures"] = errors if known else []
        # A known assertion exit (1) may retain evidence; an engine crash may not.
        if completed.returncode not in (0, 1) or ((completed.returncode or errors) and not known):
            print(completed.stdout[-6000:], flush=True)
            raise RuntimeError(f"{name} failed ({completed.returncode}): {errors[:3]}")
        pictures = list(destination.glob("*.png"))
        if not pictures:
            raise RuntimeError(f"{name} produced no screenshots")
        for path in pictures:
            pixels = Image.open(path).convert("RGBA")
            manifest["pixels"][str(path.relative_to(run_root))] = {
                "size": list(pixels.size),
                "sha256": hashlib.sha256(pixels.tobytes()).hexdigest(),
            }
        (run_root / "capture.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    (run_root / "capture.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    print(f"Saved {len(manifest['pixels'])} production UI screenshots", flush=True)


def compare(before: str, after: str) -> bool:
    left, right = OUTPUT / before, OUTPUT / after
    baseline = json.loads((left / "capture.json").read_text(encoding="utf-8"))
    current = json.loads((right / "capture.json").read_text(encoding="utf-8"))
    report = {"before": before, "after": after, "matched": [], "failures": []}
    for name, expected in baseline["pixels"].items():
        if name not in current["pixels"]:
            report["failures"].append({"file": name, "reason": "missing screenshot"})
            continue
        if expected == current["pixels"][name]:
            report["matched"].append(name)
            continue
        a, b = Image.open(left / name).convert("RGBA"), Image.open(right / name).convert("RGBA")
        if a.size != b.size:
            report["failures"].append({"file": name, "reason": "size changed"})
            continue
        difference = ImageChops.difference(a, b)
        changed = sum(x != y for x, y in zip(a.getdata(), b.getdata()))
        item = {"file": name, "changed_pixels": changed, "total_pixels": a.width * a.height}
        if changed:
            report["failures"].append(item)
            diff_path = right / "differences" / name
            diff_path.parent.mkdir(parents=True, exist_ok=True)
            difference.convert("RGB").save(diff_path)
        else:
            report["matched"].append(name)
    report["passed"] = not report["failures"]
    (right / ("comparison-" + before + ".json")).write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps({"matched": len(report["matched"]), "failures": report["failures"]}, indent=2))
    return report["passed"]


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stage", default="baseline")
    parser.add_argument("--theme", default="default")
    parser.add_argument("--godot", default=os.environ.get("GODOT_EXE", str(Path.home() / ".local/bin/godot.exe")))
    parser.add_argument("--fixtures", nargs="+", choices=list(FIXTURES), default=list(FIXTURES))
    parser.add_argument("--compare", nargs=2, metavar=("BEFORE", "AFTER"))
    parser.add_argument("--source-ref", default="", help="Mount historical scripts/shaders/tests before rendering; resources stay in the current project")
    parser.add_argument("--update", action="store_true", help="Explicitly recapture selected fixtures in an existing manifest of the same revision/theme")
    args = parser.parse_args()
    if args.compare:
        sys.exit(0 if compare(*args.compare) else 1)
    capture(args.stage, args.theme, args.godot, args.fixtures, args.source_ref, args.update)
