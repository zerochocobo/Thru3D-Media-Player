"""Desktop GLES pixel checks for the production static PiP feather mask.

No headset, decoder or APK. --modules may name disposable moderngl dependencies.
"""
import argparse
import json
from pathlib import Path
import re
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--modules", type=Path)
    parser.add_argument("--output", type=Path, default=Path("build/output/video-pip/inward-mask-gpu.json"))
    args = parser.parse_args()
    if args.modules:
        sys.path.insert(0, str(args.modules.resolve()))
    import moderngl as gl
    import numpy as np

    root = Path(__file__).resolve().parents[1]
    source = (root / "native/xr-layer/pip_feather_shader.h").read_text()
    vertex, fragment = re.findall(r'R"GLSL\((.*?)\)GLSL";', source, re.S)
    ctx = gl.create_standalone_context(require=330)
    ctx.disable_direct(0x0BD0) # GL_DITHER, also disabled by the native draw.
    program = ctx.program(vertex_shader=vertex, fragment_shader=fragment)
    vao = ctx.vertex_array(program, [])
    tile, gutter = 512, 2
    stride = tile + 2 * gutter
    feathers = ((0.025, 0.05), (0.08, 0.045), (0.01, 0.04))
    program["tile_size"] = (tile, tile)
    yy, xx = np.mgrid[:stride, :stride]
    uv = np.stack(((xx + 0.5 - gutter) / tile, (yy + 0.5 - gutter) / tile), axis=-1)
    maximum, checks = {}, 0
    # Separately test the shader's floating calculation and RGBA8 conversion.
    # UNORM output is bounded to one code value; do not conflate its conversion
    # precision with shader arithmetic (verified to 1e-5 in the float target).
    for dtype, tolerance in (("f4", 1e-5), ("f1", 1 / 255)):
        masks = ctx.texture((stride, stride * 3), 4, dtype=dtype)
        target = ctx.framebuffer([masks]); target.use()
        for row, feather in enumerate(feathers):
            ctx.viewport = (0, row * stride, stride, stride)
            program["first_row"] = row * stride
            program["feather"] = feather
            vao.render(vertices=3)
        pixels = np.frombuffer(target.read(components=4, alignment=1, dtype=dtype),
                               dtype="u1" if dtype == "f1" else "f4").reshape(stride * 3, stride, 4)
        if dtype == "f1": pixels = pixels / 255.0
        maximum[dtype] = 0.0
        for row, feather in enumerate(feathers):
            t = np.clip(np.minimum(uv, 1 - uv) / feather, 0, 1)
            expected = np.prod(t * t * (3 - 2 * t), axis=-1)
            actual = pixels[row * stride:(row + 1) * stride]
            error = float(np.max(np.abs(actual[:, :, 3] - expected)))
            assert error <= tolerance, (dtype, error)
            assert np.max(actual[:, :, :3]) == 0
            assert np.max(actual[:gutter, :, 3]) == 0 and np.max(actual[-gutter:, :, 3]) == 0
            assert np.max(actual[:, :gutter, 3]) == 0 and np.max(actual[:, -gutter:, 3]) == 0
            maximum[dtype] = max(maximum[dtype], error)
            checks += 4

    # Real GL separate RGB/alpha factors, as used by native MASK_WRITE/MASKED.
    blend_program = ctx.program(vertex_shader=vertex, fragment_shader="""#version 300 es
precision highp float;
uniform highp sampler2D masks;
uniform int row;
uniform vec3 color;
uniform bool write_mask;
out highp vec4 result;
void main() {
    result = write_mask ? texelFetch(masks,ivec2(gl_FragCoord.xy)+ivec2(2,row*516+2),0) : vec4(color,1.0);
}
""")
    blend_vao = ctx.vertex_array(blend_program, [])
    output = ctx.simple_framebuffer((tile, tile), components=4, dtype="f4")
    output.use(); ctx.viewport = (0, 0, tile, tile)
    masks.use(0); blend_program["masks"] = 0
    colors = ((1, 0.2, 0.1), (0.1, 0.8, 0.3), (0.2, 0.3, 1))
    for background in ((0, 0, 0), (0.6, 0.4, 0.2), (0.1, 0.7, 0.9)):
        output.clear(*background, 1)
        expected = np.broadcast_to(background, (tile, tile, 3)).copy()
        ctx.enable(gl.BLEND)
        for row, color in enumerate(colors):
            blend_program["row"] = row; blend_program["write_mask"] = True
            ctx.blend_func = (gl.ZERO, gl.ONE_MINUS_SRC_ALPHA, gl.ONE, gl.ZERO)
            blend_vao.render(vertices=3)
            blend_program["write_mask"] = False; blend_program["color"] = color
            ctx.blend_func = (gl.DST_ALPHA, gl.ONE, gl.ZERO, gl.ONE)
            blend_vao.render(vertices=3)
            alpha = pixels[row*stride+gutter:row*stride+gutter+tile, gutter:gutter+tile, 3:4]
            expected = np.asarray(color) * alpha + expected * (1 - alpha)
            actual = np.frombuffer(output.read(components=4, dtype="f4"), dtype="f4").reshape(tile, tile, 4)
            error = float(np.max(np.abs(actual[:, :, :3] - expected)))
            assert error < 2e-6, error
            checks += 1
        ctx.disable(gl.BLEND)
    result = {"checks": checks, "failures": 0, "mask_max_error": maximum,
              "mask_pixels_checked": stride * stride * 3, "renderer": ctx.info["GL_RENDERER"],
              "scope": "production GLES mask and GL blend factors; not OpenXR/runtime/performance validation"}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
