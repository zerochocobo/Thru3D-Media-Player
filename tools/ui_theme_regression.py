"""Run theme and existing UI regressions serially, retaining complete logs in build/."""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
BASE = ["test_ui_theme", "test_custom_palette", "test_custom_theme", "test_footer_brand", "test_choice_fields", "test_menu_tooltips"]
REGRESSIONS = [
    "test_library_menu", "test_player_menu", "test_photos", "test_player_sticks",
    "test_web_video_home", "test_web_browser_panel", "test_web_browser_start_page",
    "test_web_browser_toolbar", "test_web_browser_windows", "test_web_browser_focus",
    "test_account_panel", "test_account_composition", "test_account_modal_controls",
    "test_music_quick_controls", "test_background_audio", "test_scenery_integration",
    "test_puzzle_integration", "test_chinese_input", "test_chinese_keyboard_controls",
    "test_i18n", "test_seek_feedback", "test_immersive_adjustments", "test_layer_cadence",
    "test_mono_menu_pointer", "test_menu_surface_layout",
]


def run(godot: str, names: list[str], graphics: bool = False, source_pack: str = "", report_name: str = "regressions") -> bool:
    output = ROOT / "build/output/ui-themes" / report_name
    output.mkdir(parents=True, exist_ok=True)
    report = {"tests": [], "passed": True, "scope": "Desktop Godot; no APK or headset operations"}
    report["source_pack"] = source_pack or "working-tree"
    for name in names:
        command = [godot, "--xr-mode", "off", "--path", str(ROOT / "app/godot")]
        if graphics:
            command += ["--rendering-method", "gl_compatibility", "--rendering-driver", "opengl3"]
        else:
            command += ["--headless"]
        env = os.environ.copy()
        if source_pack:
            bootstrap = ROOT / "tmp/ui-themes/regression_reference_boot.gd"
            bootstrap.parent.mkdir(parents=True, exist_ok=True)
            bootstrap.write_text('''extends SceneTree
func _initialize() -> void:
	if not ProjectSettings.load_resource_pack(OS.get_environment("UI_THEME_REFERENCE_PACK"), true): quit(1); return
	set_script(load(OS.get_environment("UI_THEME_FIXTURE_SCRIPT")))
	call("_initialize")
''', encoding="utf-8")
            command += ["--script", str(bootstrap)]
            env.update(UI_THEME_REFERENCE_PACK=str(Path(source_pack).resolve()), UI_THEME_FIXTURE_SCRIPT="res://tests/" + name + ".gd")
        else:
            command += ["--script", "res://tests/" + name + ".gd"]
        log_path = output / (name + ".log")
        try:
            # Keep diagnostics visible while running, including a script that never quits.
            with log_path.open("w", encoding="utf-8") as stream:
                result = subprocess.run(command, cwd=ROOT, env=env, stdout=stream, stderr=subprocess.STDOUT,
                                        timeout=120, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            log = log_path.read_text(encoding="utf-8", errors="replace")
            errors = re.findall(r"(?m)^(?:SCRIPT ERROR:|SHADER ERROR:|ERROR:|FAIL:).*", log)
            passed = result.returncode == 0 and not errors
            record = {"name": name, "exit_code": result.returncode, "passed": passed, "errors": errors}
        except subprocess.TimeoutExpired:
            log = log_path.read_text(encoding="utf-8", errors="replace")
            record = {"name": name, "passed": False, "errors": ["Timed out; completion unproven"]}
            passed = False
        print(f"{name}: {'passed' if passed else 'FAILED'}", flush=True)
        if not passed:
            print(log[-4000:], flush=True)
            report["passed"] = False
        report["tests"].append(record)
        (output / "verification.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    return report["passed"]


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default=os.environ.get("GODOT_EXE", str(Path.home() / ".local/bin/godot.exe")))
    parser.add_argument("--regressions", action="store_true")
    parser.add_argument("--graphics", action="store_true")
    parser.add_argument("--tests", nargs="+")
    parser.add_argument("--source-pack", default="", help="Read-only historical scripts/shaders PCK produced by ui_theme_check.py")
    parser.add_argument("--report", default="regressions")
    args = parser.parse_args()
    names = args.tests or (BASE + REGRESSIONS if args.regressions else BASE)
    sys.exit(0 if run(args.godot, names, args.graphics, args.source_pack, args.report) else 1)
