"""Evaluates Anime4K mpv hook shaders with numpy (float64), straight from the hook files, to check the
GLES conversion. Usage: reference.py <in.png> <out.rgba> <hook.glsl> [hook.glsl ...]"""
import re
import sys

import numpy as np
from PIL import Image


def shift(t, dx, dy):
    """t sampled at (x + dx, y + dy), clamped to the edge. t is [rows, cols, 4]; y counts rows."""
    h, w, _ = t.shape
    ys = np.clip(np.arange(h) + dy, 0, h - 1)
    xs = np.clip(np.arange(w) + dx, 0, w - 1)
    return t[ys][:, xs]


def bilinear2x(t):
    h, w, _ = t.shape
    def axis(n):
        p = (np.arange(2 * n) + 0.5) / 2 - 0.5
        lo = np.floor(p).astype(int)
        f = p - lo
        return np.clip(lo, 0, n - 1), np.clip(lo + 1, 0, n - 1), f
    y0, y1, fy = axis(h)
    x0, x1, fx = axis(w)
    fx = fx[None, :, None]
    fy = fy[:, None, None]
    top = t[y0][:, x0] * (1 - fx) + t[y0][:, x1] * fx
    bottom = t[y1][:, x0] * (1 - fx) + t[y1][:, x1] * fx
    return top * (1 - fy) + bottom * fy


def run(path, textures):
    text = open(path, encoding="utf-8").read()
    for block in re.split(r"(?m)^(?=//!DESC)", text)[1:]:
        save = re.search(r"//!SAVE (\w+)", block).group(1)
        if "Depth-to-Space" in block:
            last = textures["conv2d_last_tf"]
            h, w, _ = last.shape
            up = np.repeat(np.repeat(last, 2, axis=0), 2, axis=1)
            iy = (np.arange(2 * h) % 2)[:, None]
            ix = (np.arange(2 * w) % 2)[None, :]
            c = np.take_along_axis(up, (iy * 2 + ix)[:, :, None], axis=2)[:, :, 0]
            textures[save] = np.repeat(c[:, :, None], 4, axis=2) + bilinear2x(textures["MAIN"])
            continue
        result = None
        for line in block.splitlines():
            m = re.search(r"mat4\(([^)]*)\) \* (go?_\d+)(?:\(([-\d.]+), ([-\d.]+)\))?", line)
            if m:
                matrix = np.array([float(v) for v in m.group(1).split(",")]).reshape(4, 4).T
                name = m.group(2)
                line_def = re.search(rf"#define {name}\b.*", block).group(0)
                tex = re.search(r"(\w+?)_tex", line_def).group(1)
                value = textures[tex]
                if m.group(3) is not None:
                    value = shift(value, int(float(m.group(3))), int(float(m.group(4))))
                if "max(-" in line_def:
                    value = np.maximum(-value, 0.0)
                elif "max(" in line_def:
                    value = np.maximum(value, 0.0)
                term = value @ matrix.T
                result = term if result is None else result + term
                continue
            m = re.search(r"result \+= vec4\(([^)]*)\)", line)
            if m:
                result = result + np.array([float(v) for v in m.group(1).split(",")])
        if "return result + MAIN_tex(MAIN_pos)" in block:
            result = result + textures["MAIN"]
        textures[save] = result
    return textures


def main():
    image = np.asarray(Image.open(sys.argv[1]).convert("RGBA"), dtype=np.float64) / 255.0
    for path in sys.argv[3:]:
        image = run(path, {"MAIN": image})["MAIN"]
    out = (np.clip(image, 0, 1) * 255 + 0.5).astype(np.uint8)
    open(sys.argv[2], "wb").write(out.tobytes())
    print(out.shape)


main()
