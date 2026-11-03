"""Desktop source-mask/UI probe. User media stays in build/, never in test fixtures.

Uses the production Godot player material and independent six-rectangle reconstruction.
Does not build an APK, connect to a headset, or claim Android decoder validation.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]


def unpack(frame: np.ndarray) -> np.ndarray:
    height, width = frame.shape[:2]
    aw, ah = round(width * .4) & ~3, round(height * .4) & ~1
    quarter, half = aw // 4, ah // 2
    # Reassemble the entire mask from six rectangles, independently of shader texel lookup.
    rows = []
    for y in (height - half, 0):
        rows.append(np.concatenate((frame[y:y + half, width // 2 - quarter:width // 2 + quarter, 0],
                                    frame[y:y + half, width - quarter:width, 0],
                                    frame[y:y + half, :quarter, 0]), axis=1))
    return np.concatenate(rows, axis=0)


def bilinear(mask: np.ndarray, u: np.ndarray, v: np.ndarray) -> np.ndarray:
    h, w = mask.shape
    px, py = np.clip(u * w - .5, 0, w - 1), np.clip(v * h - .5, 0, h - 1)
    x, y = px.astype(int), py.astype(int)
    xx, yy = np.minimum(x + 1, w - 1), np.minimum(y + 1, h - 1)
    fx, fy = px - x, py - y
    return ((mask[y, x] * (1 - fx) + mask[y, xx] * fx) * (1 - fy)
            + (mask[yy, x] * (1 - fx) + mask[yy, xx] * fx) * fy)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("video", type=Path)
    parser.add_argument("--godot", default=os.environ.get("GODOT_EXE", "godot"))
    parser.add_argument("--ffmpeg", default="ffmpeg")
    parser.add_argument("--ffprobe", default="ffprobe")
    parser.add_argument("--times", nargs="+", type=float, default=[12, 38, 64])
    parser.add_argument("--output", type=Path, default=ROOT / "build/output/native-alpha-sample")
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    metadata = json.loads(subprocess.check_output([args.ffprobe, "-v", "error", "-show_streams",
                                                  "-show_format", "-of", "json", str(args.video)], text=True, encoding="utf-8"))
    (output / "metadata.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2), encoding="utf-8")
    entries = []
    for index, seconds in enumerate(args.times):
        frame_path = output / f"source-{index}.png"
        subprocess.run([args.ffmpeg, "-hide_banner", "-loglevel", "error", "-ss", str(seconds),
                        "-i", str(args.video), "-frames:v", "1", "-y", str(frame_path)], check=True)
        frame = np.asarray(Image.open(frame_path).convert("RGB"))
        mask_path = output / f"mask-{index}.png"
        Image.fromarray(unpack(frame)).save(mask_path)
        entries.append({"frame": str(frame_path), "mask": str(mask_path), "seconds": seconds, "index": index})
    config = output / "input.json"
    config.write_text(json.dumps({"output": str(output), "frames": entries}), encoding="utf-8")
    env = os.environ.copy()
    env.update(NATIVE_ALPHA_PROBE_INPUT=str(config), APPDATA=str(output / "appdata"), SDL_JOYSTICK_HIDAPI="0")
    command = [args.godot, "--xr-mode", "off", "--rendering-method", "gl_compatibility", "--rendering-driver", "opengl3",
               "--path", str(ROOT / "app/godot"), "--script", "res://tests/render_native_alpha.gd"]
    flags = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0
    with (output / "render.log").open("w", encoding="utf-8") as log:
        subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=180, creationflags=flags)
    log_text = (output / "render.log").read_text(encoding="utf-8")
    if any(marker in log_text for marker in ("SCRIPT ERROR:", "SHADER ERROR:", "ERROR:")):
        raise RuntimeError(f"Godot error; see {output / 'render.log'}")
    cases = []
    for entry in entries:
        mask = np.asarray(Image.open(entry["mask"]).convert("L"), dtype=np.float32) / 255
        for eye in range(2):
            shown = np.asarray(Image.open(output / f"alpha-{entry['index']}-{eye}.png").convert("RGBA"))
            height, width = shown.shape[:2]
            y, x = np.mgrid[:height, :width]
            # 90-degree square camera looking along -Z; equirect180 longitude/latitude.
            dx, dy = 2 * (x + .5) / width - 1, 1 - 2 * (y + .5) / height
            u = np.arctan2(dx, 1) / np.pi + .5
            v = .5 - np.arcsin(dy / np.sqrt(dx * dx + dy * dy + 1)) / np.pi
            expected = bilinear(mask, (u + eye) * .5, v)
            error = np.abs(shown[:, :, 3] / 255 - expected)
            case = {"seconds": entry["seconds"], "eye": eye, "mean_alpha_error": float(error.mean()),
                    "fraction_error_over_0_05": float((error > .05).mean()),
                    "transparent_fraction": float((shown[:, :, 3] < 16).mean()),
                    "opaque_fraction": float((shown[:, :, 3] > 239).mean())}
            # The production hemisphere is tessellated; interpolation differs near curved edges.
            case["passed"] = case["mean_alpha_error"] < .01 and case["fraction_error_over_0_05"] < .01
            cases.append(case)
            checker = np.where(((x // 24 + y // 24) % 2)[..., None], [63, 72, 82], [37, 44, 53])
            alpha = shown[:, :, 3:4] / 255
            preview = shown[:, :, :3] * alpha + checker * (1 - alpha)
            Image.fromarray(np.uint8(np.clip(preview, 0, 255))).save(output / f"preview-{entry['index']}-{eye}.png")
    with args.video.open("rb") as source:
        digest = hashlib.file_digest(source, "sha256").hexdigest()
    report = {"source_sha256": digest, "source_bytes": args.video.stat().st_size,
              "scope": "Decoded sample frames and production desktop Godot shader/UI; Android/XR playback not tested",
              "cases": cases, "passed": all(c["passed"] for c in cases)}
    (output / "verification.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(report, indent=2))
    if not report["passed"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
