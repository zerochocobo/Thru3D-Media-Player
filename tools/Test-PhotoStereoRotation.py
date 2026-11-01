"""Desktop GL verification of the production native compute/frame shaders. No APK/device.

Requires numpy and moderngl; --python-libs can point to a disposable pip --target directory.
"""
import argparse
import json
import re
import sys
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--python-libs", type=Path)
    parser.add_argument("--output", type=Path, default=Path("build/output/photo-rotation-fix/gpu"))
    args = parser.parse_args()
    if args.python_libs:
        sys.path.insert(0, str(args.python_libs.resolve()))
    import moderngl as gl
    import numpy as np

    root = Path(__file__).resolve().parents[1]
    text = (root / "native/render-bridge/render_bridge.cpp").read_text(encoding="utf-8")

    def shader(name):
        value = re.search(r"constexpr const char\* " + name + r' = R"\((.*?)\)";', text, re.S)[1]
        value = re.sub(r"#version \d+ es", "#version 430", value)
        return re.sub(r"precision (?:highp|mediump) (?:float|int);", "", value)

    ctx = gl.create_standalone_context(require=430)
    common = shader("warp_common")
    clear = ctx.compute_shader(common + shader("warp_clear"))
    scatter = ctx.compute_shader(common + shader("warp_scatter"))
    classify = ctx.compute_shader(common + shader("warp_classify"))
    frame = ctx.program(
        vertex_shader="#version 430\nvoid main(){vec2 p=vec2((gl_VertexID<<1)&2,gl_VertexID&2);gl_Position=vec4(p*2.-1.,0.,1.);}",
        fragment_shader=shader("warp_frame_2d") + shader("warp_frame_body"),
    )
    vao = ctx.vertex_array(frame, [])
    checks, results, failures = 0, [], []

    def check(ok, message):
        nonlocal checks
        checks += 1
        if not ok:
            failures.append(message)

    def render(color, depth, turns, strength):
        h, w, _ = color.shape
        rotated_depth = np.ascontiguousarray(np.rot90(depth, -turns))
        mh, mw = rotated_depth.shape
        rw, rh = (h, w) if turns % 2 else (w, h)
        source = ctx.texture((w, h), 4, color.tobytes(), dtype="f1")
        source.filter = gl.LINEAR, gl.LINEAR
        source.repeat_x = source.repeat_y = False
        near = ctx.texture((mw, mh), 1, np.rint(rotated_depth * 255).astype(np.uint8).tobytes(), dtype="f1")
        near.repeat_x = near.repeat_y = False
        keys = ctx.buffer(reserve=rw * 2 * rh * 4)
        mapping = ctx.texture((rw * 2, rh), 4, dtype="f2")
        mapping.filter = gl.NEAREST, gl.NEAREST
        output = ctx.texture((w * 2, h), 4, dtype="f1")
        target = ctx.framebuffer([output])
        resources = [source, near, keys, mapping, output, target]
        keys.bind_to_storage_buffer(0)
        near.use(0)
        half = max(2.0, min(96.0, rw * .035)) * strength * .5
        for program in [clear, scatter, classify]:
            for name, value in {"near_map": 0, "size": (rw, rh), "model": (mw, mh),
                                "content": (0., 0., 1., 1.), "shift": (half, .35), "text_count": 0}.items():
                if name in program:
                    program[name] = value
        clear["count"] = rw * 2 * rh
        clear.run((rw * 2 * rh + 255) // 256)
        ctx.memory_barrier()
        scatter.run((rw + 7) // 8, (rh + 7) // 8)
        ctx.memory_barrier()
        classify["rim"] = max(2, round(rw / 120))
        classify["fg_win"] = max(2, round(rw / 240))
        mapping.bind_to_image(0, read=False, write=True)
        classify.run((rw * 2 + 7) // 8, (rh + 7) // 8)
        ctx.memory_barrier()
        target.use()
        ctx.viewport = 0, 0, w * 2, h
        source.use(0)
        mapping.use(1)
        frame["source"], frame["map"] = 0, 1
        frame["size"], frame["uv_scale"], frame["photo_rotation"] = (rw, rh), (1., 1.), turns
        vao.render(vertices=3)
        pixels = np.frombuffer(target.read(components=4, alignment=1), dtype=np.uint8).reshape(h, w * 2, 4).copy()
        for resource in reversed(resources):
            resource.release()
        return pixels

    def center(pixels):
        ys, xs = np.where((pixels[:, :, 0] > 220) & (pixels[:, :, 1] < 40))
        check(len(xs) > 50, "Rendered marker is present")
        return np.array([xs.mean(), ys.mean()])

    args.output.mkdir(parents=True, exist_ok=True)
    for w, h in [(192, 128), (128, 192), (257, 95)]:
        color = np.full((h, w, 4), 80, np.uint8)
        color[:, :, 3] = 255
        color[h // 3: h * 2 // 3, w // 3: w * 2 // 3, :3] = [240, 10, 30]
        depth = np.full((24, 32), .95, np.float32)
        for turns in range(4):
            zero = render(color, depth, turns, 0.)
            for eye in range(2):
                check(np.array_equal(zero[:, eye*w:(eye+1)*w], color), f"Zero strength exact RGBA/eye packing {w}x{h} r{turns}")
            for strength in [.5, 1., 2.]:
                pair = render(color, depth, turns, strength)
                eyes = [np.rot90(pair[:, eye*w:(eye+1)*w], -turns) for eye in range(2)]
                disparity = center(eyes[1]) - center(eyes[0])
                rw = h if turns % 2 else w
                half = max(2.0, min(96.0, rw * .035)) * strength * .5
                expected = -2 * np.floor((round(.95*255)/255-.35) * half + .5)
                check(abs(disparity[0]-expected) < .05 and abs(disparity[1]) < .05, f"Viewer-horizontal signed disparity {w}x{h} r{turns} s{strength}: {disparity}, expected {expected}")
                check(np.all(pair[:, :, 3] == 255), "Warp stays opaque")
                results.append({"width": w, "height": h, "rotation": turns*90, "strength": strength, "right_minus_left": disparity.tolist()})
                if w == 192 and strength == 1.:
                    (args.output / f"pair-r{turns*90}.rgba").write_bytes(pair.tobytes())
    report = {"checks": checks, "failures": failures, "cases": results, "renderer": ctx.info["GL_RENDERER"],
              "scope": "Production native shader strings on desktop OpenGL; not Android EGL or XR. Constant-depth fixtures isolate orientation and eye order."}
    (args.output / "report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(f"Photo stereo rotation GPU: {checks} checks, {len(failures)} failures")
    for failure in failures:
        print(f"FAIL: {failure}")
    return bool(failures)


if __name__ == "__main__":
    raise SystemExit(main())
