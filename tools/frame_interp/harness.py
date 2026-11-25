"""Runs frame interpolation's shaders (native/xr-layer/interp_glsl.h) on a desktop GPU.

The pass order here is the one frame_interp.cpp follows. Frames are raw rgb48le files (ffmpeg -pix_fmt rgb48le
-f rawvideo); results are compared with a reference frame (PSNR) and written as PNG crops to look at.

  python harness.py pair A.raw:0 B.raw:1 --size 3840x2160 --phase 0.5 [--truth T.raw:1] [--out dir]

Needs moderngl, numpy and pillow.
"""
import argparse, ast, math, os, re, sys, time
import numpy as np
import moderngl

HEADER = os.path.join(os.path.dirname(__file__), "..", "..", "native", "xr-layer", "interp_glsl.h")


def shaders(path=HEADER):
    """The header's string macros, references to other macros resolved."""
    text = open(path, encoding="utf-8").read()
    raw = {}
    for name, body in re.findall(r"#define (\w+) \\\n((?:.*\\\n)*.*\n)", text):
        raw[name] = re.findall(r'"(?:[^"\\]|\\.)*"|\b[A-Z_]{4,}\b', body)

    def resolve(name):
        return "".join(ast.literal_eval(token) if token.startswith('"') else resolve(token) for token in raw[name])

    return {name: resolve(name) for name in raw}


def desktop(source):
    source = source.replace("#version 300 es", "#version 330")
    source = re.sub(r"#extension [^\n]*\n", "", source)
    source = re.sub(r"precision \w+ float;\n", "", source)
    return source.replace("samplerExternalOES", "sampler2D")


class Interpolator:
    def __init__(self, ctx, width, height, penalty=0.004, cut=(0.03, 0.45), doubt=(0.012, 0.03), even=1, soften=2, firm=0.004, eyes=1):
        """eyes 2: the frames are side by side stereo pairs (2D->3D), width across both."""
        self.ctx, self.width, self.height, self.penalty, self.cut, self.doubt, self.even_passes, self.soften_passes, self.firm = ctx, width, height, penalty, cut, doubt, even, soften, firm
        self.eyes = eyes
        self.split = (float(eyes), 1.0)
        glsl = {name: desktop(source) for name, source in shaders().items()}
        vertex = glsl["INTERP_VERTEX_GLSL"]
        self.luma_program = ctx.program(vertex_shader=vertex, fragment_shader=glsl["INTERP_LUMA_GLSL"])
        self.search = ctx.program(vertex_shader=vertex, fragment_shader=glsl["INTERP_SEARCH_GLSL"])
        self.refine = ctx.program(vertex_shader=vertex, fragment_shader=glsl["INTERP_REFINE_GLSL"])
        self.even = ctx.program(vertex_shader=vertex, fragment_shader=glsl["INTERP_EVEN_GLSL"])
        self.soften = ctx.program(vertex_shader=vertex, fragment_shader=glsl["INTERP_SOFTEN_GLSL"])
        self.between = ctx.program(vertex_shader=vertex, fragment_shader=glsl["INTERP_BETWEEN_GLSL"])
        self.vaos = {id(p): ctx.vertex_array(p, []) for p in (self.luma_program, self.search, self.refine, self.even, self.soften, self.between)}
        # As frame_interp.cpp's ensure: everything is sized for one eye picture, then laid side by side.
        eye = width // eyes
        self.reduction = 4 if eye > 2560 else 2
        eye_luma = math.ceil(eye / self.reduction)
        self.luma_size = (eye_luma * eyes, math.ceil(height / self.reduction))
        # Levels down to about 30 pixels across: the coarsest search reaches two of its pixels.
        self.top = max(0, int(math.floor(math.log2(eye_luma / 24.0))))
        self.field_sizes = [(math.ceil(max(1, eye_luma >> level) / 4) * eyes, math.ceil(max(1, self.luma_size[1] >> level) / 4))
                            for level in range(self.top + 1)]
        # As frame_interp.cpp: the finest level keeps the grid of the level above it.
        if self.top >= 1 and not os.environ.get("INTERP_FINE_FIELD"): self.field_sizes[0] = self.field_sizes[1]

    def draw(self, program, target, **uniforms):
        uniforms["split"] = self.split
        for name, value in uniforms.items():
            if name in program: program[name].value = value
        target.use()
        self.ctx.viewport = (0, 0, target.width, target.height)
        self.vaos[id(program)].render(moderngl.TRIANGLES, vertices=3)

    def frame(self, pixels):
        texture = self.ctx.texture((self.width, self.height), 3, (pixels / 65535.0).astype("f4").tobytes(), dtype="f4")
        texture.filter = (moderngl.LINEAR, moderngl.LINEAR)
        texture.repeat_x = texture.repeat_y = False
        return texture

    def luma(self, frame):
        texture = self.ctx.texture(self.luma_size, 1, dtype="f2")
        frame.use(0)
        tap = self.reduction / 4.0
        self.draw(self.luma_program, self.ctx.framebuffer([texture]), frame=0, scale=(1.0, 1.0), tap=(tap / self.width, tap / self.height))
        texture.build_mipmaps()
        texture.filter = (moderngl.LINEAR_MIPMAP_NEAREST, moderngl.LINEAR)
        texture.repeat_x = texture.repeat_y = False
        return texture

    def field(self, start, end):
        """Motion from luma `start` to luma `end`."""
        start.use(0); end.use(1)
        parent = None
        common = dict(size=tuple(float(v) for v in self.luma_size), penalty=self.penalty)
        common["from"] = 0; common["to"] = 1
        for level in range(self.top, -1, -1):
            texture = self.ctx.texture(self.field_sizes[level], 4, dtype="f2")
            texture.filter = (moderngl.NEAREST, moderngl.NEAREST)
            if parent: parent.use(2)
            self.draw(self.search, self.ctx.framebuffer([texture]), parent=2, first=parent is None,
                      lod=float(level), pitch=float(1 << level), **common)
            parent = texture
        result = self.ctx.texture(self.field_sizes[0], 4, dtype="f2")
        parent.use(2)
        self.draw(self.refine, self.ctx.framebuffer([result]), field=2, lod=0.0, pitch=1.0, **common)
        for _ in range(self.even_passes):
            evened = self.ctx.texture(self.field_sizes[0], 4, dtype="f2")
            result.filter = (moderngl.NEAREST, moderngl.NEAREST)
            result.use(2)
            self.draw(self.even, self.ctx.framebuffer([evened]), field=2)
            result = evened
        for _ in range(self.soften_passes):
            softened = self.ctx.texture(self.field_sizes[0], 4, dtype="f2")
            result.filter = (moderngl.NEAREST, moderngl.NEAREST)
            result.use(2)
            self.draw(self.soften, self.ctx.framebuffer([softened]), field=2, firm=self.firm)
            result = softened
        result.build_mipmaps()
        result.filter = (moderngl.LINEAR_MIPMAP_NEAREST, moderngl.LINEAR)
        result.repeat_x = result.repeat_y = False
        return result

    def mix(self, before, after, forward, backward, phase):
        target = self.ctx.texture((self.width, self.height), 3, dtype="f4")
        before.use(0); after.use(1); forward.use(2); backward.use(3)
        self.draw(self.between, self.ctx.framebuffer([target]), before=0, after=1, forward=2, backward=3, scale=(1.0, 1.0),
                  size=tuple(float(v) for v in self.luma_size), phase=float(phase), cut=self.cut, doubt=self.doubt,
                  margin=(0.5 / self.width, 0.5 / self.height) if self.eyes > 1 else (0.0, 0.0))
        return np.round(np.clip(np.frombuffer(target.read(), np.float32), 0.0, 1.0) * 65535.0).astype(np.uint16).reshape(self.height, self.width, 3)


def load(spec, width, height):
    path, _, index = spec.rpartition(":")
    count = width * height * 6
    with open(path, "rb") as source:
        source.seek(int(index) * count)
        return np.frombuffer(source.read(count), np.uint16).reshape(height, width, 3)


def psnr(a, b):
    error = np.mean((a.astype(np.float64) - b.astype(np.float64)) ** 2)
    return 99.0 if error == 0 else 10 * math.log10(65535.0 ** 2 / error)


def save(path, pixels, gain=1.0):
    from PIL import Image
    Image.fromarray(np.clip(pixels.astype(np.float32) / 257.0 * gain, 0, 255).astype(np.uint8)).save(path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("before"); parser.add_argument("after")
    parser.add_argument("--size", default="3840x2160")
    parser.add_argument("--phase", type=float, nargs="+", default=[0.5])
    parser.add_argument("--truth", nargs="*", default=[], help="one reference frame for each phase")
    parser.add_argument("--penalty", type=float, default=0.004)
    parser.add_argument("--cut", type=float, nargs=2, default=[0.03, 0.45])
    parser.add_argument("--doubt", type=float, nargs=2, default=[0.012, 0.03])
    parser.add_argument("--even", type=int, default=1)
    parser.add_argument("--soften", type=int, default=2)
    parser.add_argument("--firm", type=float, default=0.004)
    parser.add_argument("--out", default="")
    parser.add_argument("--gain", type=float, default=1.0, help="brightens the PNGs (PQ frames look dim)")
    parser.add_argument("--crop", default="", help="x,y,w,h of the PNGs")
    parser.add_argument("--pair", type=int, default=-1, metavar="SHIFT", help="as a 2D->3D stereo pair: each frame at half size twice, "
                        "side by side, the right eye's picture SHIFT pixels to the left; the PSNR is then of the whole pair")
    args = parser.parse_args()
    width, height = (int(v) for v in args.size.split("x"))
    ctx = moderngl.create_standalone_context()

    full = height

    def load_frame(spec):
        frame = load(spec, width, full)
        if args.pair < 0: return frame
        half = frame[::2, ::2]
        return np.concatenate([half, np.roll(half, -args.pair, axis=1)], axis=1)

    if args.pair >= 0: height //= 2 # the pair is two half-size pictures across: as wide as the frame, half as tall
    tool = Interpolator(ctx, width, height, args.penalty, tuple(args.cut), tuple(args.doubt), args.even, args.soften, args.firm,
                        2 if args.pair >= 0 else 1)
    first, second = load_frame(args.before), load_frame(args.after)
    before, after = tool.frame(first), tool.frame(second)
    ctx.finish(); started = time.perf_counter()
    luma_before, luma_after = tool.luma(before), tool.luma(after)
    forward, backward = tool.field(luma_before, luma_after), tool.field(luma_after, luma_before)
    ctx.finish(); estimated = time.perf_counter() - started
    field = np.frombuffer(forward.read(), np.float16).reshape(forward.height, forward.width, 4).astype(np.float32)
    print(f"luma {tool.luma_size} levels {tool.top + 1} field {tool.field_sizes[0]} estimate {estimated * 1000:.1f} ms")
    print(f"forward motion (luma px): mean {field[..., 0].mean():+.2f},{field[..., 1].mean():+.2f} "
          f"p95 |v| {np.percentile(np.hypot(field[..., 0], field[..., 1]), 95):.1f} match mean {field[..., 2].mean():.4f} p95 {np.percentile(field[..., 2], 95):.4f}")
    crop = [int(v) for v in args.crop.split(",")] if args.crop else None
    for index, phase in enumerate(args.phase):
        result = tool.mix(before, after, forward, backward, phase)
        line = f"phase {phase:.3f}"
        blend = ((1 - phase) * first.astype(np.float32) + phase * second.astype(np.float32)).astype(np.uint16)
        if index < len(args.truth):
            truth = load_frame(args.truth[index])
            nearest = first if phase < 0.5 else second
            line += f" psnr {psnr(result, truth):.2f} dB (blend {psnr(blend, truth):.2f}, nearest {psnr(nearest, truth):.2f})"
        else: truth = None
        print(line)
        if args.out:
            os.makedirs(args.out, exist_ok=True)
            views = [result, blend] + ([truth] if truth is not None else [])
            if crop: views = [view[crop[1]:crop[1] + crop[3], crop[0]:crop[0] + crop[2]] for view in views]
            save(os.path.join(args.out, f"phase_{phase:.3f}.png"), np.concatenate(views, axis=1), args.gain)
    if args.out:
        scale = 255.0 / max(1.0, float(np.abs(field[..., :2]).max()))
        picture = np.stack([field[..., 0] * scale / 2 + 127, field[..., 1] * scale / 2 + 127, np.clip(field[..., 2] * 2000, 0, 255)], axis=-1)
        from PIL import Image
        Image.fromarray(np.clip(picture, 0, 255).astype(np.uint8)).resize((960, 540), Image.NEAREST).save(os.path.join(args.out, "field.png"))


if __name__ == "__main__":
    main()
