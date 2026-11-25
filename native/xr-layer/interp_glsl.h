// GLSL of picture quality mode's frame interpolation (frame_interp.cpp): motion between two decoder
// frames, estimated coarse to fine on small luma pictures, and the picture in between drawn along it.
// The method follows MVTools (block matching through a pyramid with a coherence penalty, pictures from
// both neighbours mixed by how well each matched); the code is written for fragment shaders.
// tools/frame_interp/harness.py runs these same strings on a desktop GPU.
//
// The frames are decoder images (samplerExternalOES) on the layer copy's thread; 2D->3D's stereo pairs
// are textures, for which frame_interp.cpp builds the same programs with sampler2D in that word's place.
// `split` is the eye pictures across and down a frame (1, 1 for one picture; 2, 1 for a side by side
// pair): each eye's motion is its own, and nothing is read from the other eye's picture.
#pragma once

// The corner of the eye picture a point (0..1 of the frame) lies in.
#define INTERP_EYE_GLSL \
    "uniform vec2 split;\n" \
    "vec2 eye_low(vec2 at) { return floor(min(at, vec2(0.99999)) * split) / split; }\n"

// The cells of a field that belong to the eye picture `cell` is in: x, y the first, z, w the last. Every
// field is a whole number of cells across for each eye (frame_interp.cpp's ensure).
#define INTERP_CELLS_GLSL \
    "ivec4 eye_cells(ivec2 cell, ivec2 count) { ivec2 each = count / ivec2(split);\n" \
    "  ivec2 first = min(cell / each, ivec2(split) - 1) * each; return ivec4(first, first + each - 1); }\n"

// One triangle over the target; uv 0..1 with the picture's first row at 0.
#define INTERP_VERTEX_GLSL \
    "#version 300 es\n" \
    "out vec2 uv;\n" \
    "void main() { vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));\n" \
    "  uv = p; gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0); }\n"

// A decoder frame's luma, reduced: four bilinear taps, each tap one source pixel from the centre at a
// quarter of the size (a 4 x 4 box), half a pixel at half the size. PQ and HLG code values are
// perceptual like gamma, so differences of them compare as differences of SDR luma do.
#define INTERP_LUMA_GLSL \
    "#version 300 es\n" \
    "#extension GL_OES_EGL_image_external_essl3 : require\n" \
    "precision highp float;\n" \
    "uniform samplerExternalOES frame; uniform vec2 scale; uniform vec2 tap; in vec2 uv; out vec4 result;\n" \
    "float luma(vec2 at) { return dot(texture(frame, at).rgb, vec3(0.25, 0.5, 0.25)); }\n" \
    "void main() { vec2 at = uv * scale;\n" \
    "  result = vec4(0.25 * (luma(at + tap) + luma(at - tap) + luma(at + vec2(tap.x, -tap.y)) + luma(at + vec2(-tap.x, tap.y))), 0.0, 0.0, 1.0); }\n"

// Mean absolute difference of an 8 x 8 block around centre in `from` and the block v away in `to`, at
// mip level lod (pixels `pitch` apart). centre, v and pitch are in pixels of the luma's level 0 (size).
// Sixteen taps, each on the corner four pixels share, so bilinear filtering reads all 64: one tap a
// pixel cost four times the GPU time (Quest 3, 4K: 17.7 ms a pair). A tap past the eye picture's edge
// reads the edge, as the texture's own clamping gives for one picture.
#define INTERP_MATCH_GLSL \
    "uniform sampler2D from; uniform sampler2D to; uniform vec2 size; uniform float lod; uniform float pitch;\n" \
    INTERP_EYE_GLSL \
    "float match(vec2 centre, vec2 v) { float sum = 0.0;\n" \
    "  vec2 low = eye_low(centre / size) * size + 0.5 * pitch; vec2 high = low + size / split - pitch;\n" \
    "  for (int j = 0; j < 4; ++j) for (int i = 0; i < 4; ++i) {\n" \
    "    vec2 p = centre + (vec2(float(i), float(j)) - 1.5) * 2.0 * pitch;\n" \
    "    sum += abs(textureLod(from, clamp(p, low, high) / size, lod).r - textureLod(to, clamp(p + v, low, high) / size, lod).r); }\n" \
    "  return sum / 16.0; }\n"

// One level of the search, one vector for each 4 x 4 pixels of that level (or the grid its target has:
// the caller gives the finest level the grid of the level above): xy the motion from `from` to
// `to` in level 0 pixels, z how well it matched, w how well no motion would have. The coarsest level (first) tries every step within
// reach; the others try around the vector the level above found, its neighbours' vectors and no motion.
// A candidate that leaves its prediction pays `penalty` for each pixel of the level it strays: where the
// picture gives no reason, the field stays even.
#define INTERP_SEARCH_GLSL \
    "#version 300 es\n" \
    "precision highp float;\n" \
    INTERP_MATCH_GLSL \
    INTERP_CELLS_GLSL \
    "uniform sampler2D parent; uniform bool first; uniform float penalty; in vec2 uv; out vec4 result;\n" \
    "vec2 best; float low; float matched;\n" \
    "float attempt(vec2 centre, vec2 v, float strayed) { float m = match(centre, v); float cost = m + penalty * strayed;\n" \
    "  if (cost < low) { low = cost; best = v; matched = m; } return m; }\n" \
    "void main() { vec2 centre = uv * size; low = 1e9; best = vec2(0.0); matched = 1.0; float still = 1.0;\n" \
    "  if (first) {\n" \
    "    for (int y = -2; y <= 2; ++y) for (int x = -2; x <= 2; ++x) {\n" \
    "      vec2 v = vec2(float(x), float(y)); float m = attempt(centre, v * pitch, 0.25 * length(v)); if (x == 0 && y == 0) still = m; }\n" \
    "  } else {\n" \
    "    ivec2 count = textureSize(parent, 0);\n" \
    "    ivec2 cell = min(ivec2(uv * vec2(count)), count - 1); ivec4 own = eye_cells(cell, count);\n" \
    "    vec2 base = round(texelFetch(parent, cell, 0).xy / pitch) * pitch;\n" \
    "    for (int y = -1; y <= 1; ++y) for (int x = -1; x <= 1; ++x) {\n" \
    "      vec2 v = vec2(float(x), float(y)); attempt(centre, base + v * pitch, length(v)); }\n" \
    "    for (int k = 0; k < 4; ++k) {\n" \
    "      ivec2 beside = clamp(cell + ivec2(k == 0 ? -1 : k == 1 ? 1 : 0, k == 2 ? -1 : k == 3 ? 1 : 0), own.xy, own.zw);\n" \
    "      vec2 v = round(texelFetch(parent, beside, 0).xy / pitch) * pitch; attempt(centre, v, min(length(v - base) / pitch, 0.5)); }\n" \
    "    still = attempt(centre, vec2(0.0), min(length(base) / pitch, 1.0));\n" \
    "  }\n" \
    "  result = vec4(best, matched, still); }\n"

// The finest level's vectors to a fraction of a pixel: a parabola through the match one pixel either
// side of the vector found, along each axis.
#define INTERP_REFINE_GLSL \
    "#version 300 es\n" \
    "precision highp float;\n" \
    INTERP_MATCH_GLSL \
    "uniform sampler2D field; in vec2 uv; out vec4 result;\n" \
    "float vertex(float before, float at, float after) { float bend = before - 2.0 * at + after;\n" \
    "  return bend > 1e-5 ? clamp(0.5 * (before - after) / bend, -0.5, 0.5) : 0.0; }\n" \
    "void main() { vec2 centre = uv * size;\n" \
    "  vec4 found = texelFetch(field, ivec2(gl_FragCoord.xy), 0); vec2 v = found.xy;\n" \
    "  float at = found.z;\n" \
    "  float dx = vertex(match(centre, v - vec2(pitch, 0.0)), at, match(centre, v + vec2(pitch, 0.0)));\n" \
    "  float dy = vertex(match(centre, v - vec2(0.0, pitch)), at, match(centre, v + vec2(0.0, pitch)));\n" \
    "  result = vec4(v + vec2(dx, dy) * pitch, at, found.w); }\n"

// Vectors that stand alone are errors more often than motion: each cell takes, of the nine vectors
// around it, the one nearest to all the others (a vector median), which keeps the edges of moving things.
#define INTERP_EVEN_GLSL \
    "#version 300 es\n" \
    "precision highp float;\n" \
    INTERP_EYE_GLSL \
    INTERP_CELLS_GLSL \
    "uniform sampler2D field; in vec2 uv; out vec4 result;\n" \
    "void main() { ivec2 cell = ivec2(gl_FragCoord.xy); ivec4 own = eye_cells(cell, textureSize(field, 0));\n" \
    "  vec4 around[9];\n" \
    "  for (int k = 0; k < 9; ++k) around[k] = texelFetch(field, clamp(cell + ivec2(k % 3 - 1, k / 3 - 1), own.xy, own.zw), 0);\n" \
    "  vec4 chosen = around[4]; float low = 1e9;\n" \
    "  for (int k = 0; k < 9; ++k) { float sum = 0.0;\n" \
    "    for (int other = 0; other < 9; ++other) sum += length(around[k].xy - around[other].xy);\n" \
    "    if (sum < low) { low = sum; chosen = around[k]; } }\n" \
    "  result = vec4(chosen.xy, max(chosen.z, around[4].z), around[4].w); }\n"

// Then the field is softened, each cell towards its neighbours two cells around by how well they
// matched: steps between cells would show as tears in the picture, a gradual change only stretches it.
#define INTERP_SOFTEN_GLSL \
    "#version 300 es\n" \
    "precision highp float;\n" \
    INTERP_EYE_GLSL \
    INTERP_CELLS_GLSL \
    "uniform sampler2D field; uniform float firm; in vec2 uv; out vec4 result;\n" \
    "void main() { ivec2 cell = ivec2(gl_FragCoord.xy); ivec4 cells = eye_cells(cell, textureSize(field, 0));\n" \
    "  vec4 own = texelFetch(field, cell, 0); vec2 sum = vec2(0.0); float total = 0.0;\n" \
    "  for (int y = -2; y <= 2; ++y) for (int x = -2; x <= 2; ++x) {\n" \
    "    vec4 near = texelFetch(field, clamp(cell + ivec2(x, y), cells.xy, cells.zw), 0);\n" \
    "    float w = exp(-0.35 * float(x * x + y * y)) / (near.z + firm); sum += near.xy * w; total += w; }\n" \
    "  result = vec4(sum / total, own.zw); }\n"

// The picture at `phase` between two frames (0: before, 1: after). Each frame's pixels move along its
// own field: `forward` holds before's motion towards after, `backward` after's towards before. A pixel
// here came from where the field of the pixel that lands here says, so each field is read twice. The two
// are mixed by time and by how well the other one matched, which leaves what one frame hides to the
// frame that shows it. Where neither matched (`doubt`: the match where trust starts to go and where it
// is gone) and moving gained little over standing still (the field's w), the two frames cross-fade in
// place, which reads as motion blur where moved guesses would tear. Across a cut (`cut`: the whole
// field's mean match above x, and above y of what standing still would give) nothing moves: the nearer
// frame shows as it is. `margin` is half a pixel of a frame that holds two eye pictures (0 for one
// picture, whose edge the texture clamps to). `only` (1: before, 2: after) draws that frame as it is, and
// `linear_output` writes linear light (an sRGB target, which encodes it again): 2D->3D's pictures go
// straight into the picture layer's image.
#define INTERP_BETWEEN_GLSL \
    "#version 300 es\n" \
    "#extension GL_OES_EGL_image_external_essl3 : require\n" \
    "precision highp float;\n" \
    "uniform samplerExternalOES before; uniform samplerExternalOES after; uniform sampler2D forward; uniform sampler2D backward;\n" \
    "uniform vec2 scale; uniform vec2 size; uniform float phase; uniform vec2 cut; uniform vec2 doubt; uniform vec2 margin;\n" \
    "uniform int only; uniform bool linear_output;\n" \
    INTERP_EYE_GLSL \
    "in vec2 uv; out vec4 result;\n" \
    "vec4 shown(vec3 c) { return vec4(linear_output ? mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c)) : c, 1.0); }\n" \
    "void main() { vec2 pixel = 1.0 / size;\n" \
    "  if (only != 0) { result = shown(only == 1 ? texture(before, uv * scale).rgb : texture(after, uv * scale).rgb); return; }\n" \
    "  vec2 low = eye_low(uv); vec2 high = low + 1.0 / split;\n" \
    "  vec2 cell = 0.5 / vec2(textureSize(forward, 0)); vec2 first = low + cell; vec2 last = high - cell;\n" \
    "  vec2 whole = max(textureLod(forward, vec2(0.5), 16.0).zw, textureLod(backward, vec2(0.5), 16.0).zw);\n" \
    "  if (whole.x > cut.x && whole.x > cut.y * whole.y) { result = shown(phase < 0.5 ? texture(before, uv * scale).rgb : texture(after, uv * scale).rgb); return; }\n" \
    "  vec4 f = texture(forward, clamp(uv, first, last)); f = texture(forward, clamp(uv - phase * f.xy * pixel, first, last));\n" \
    "  vec4 b = texture(backward, clamp(uv, first, last)); b = texture(backward, clamp(uv - (1.0 - phase) * b.xy * pixel, first, last));\n" \
    "  vec3 early = texture(before, clamp(uv - phase * f.xy * pixel, low + margin, high - margin) * scale).rgb;\n" \
    "  vec3 late = texture(after, clamp(uv - (1.0 - phase) * b.xy * pixel, low + margin, high - margin) * scale).rgb;\n" \
    "  float we = (1.0 - phase) * (b.z + 0.004), wl = phase * (f.z + 0.004);\n" \
    "  vec3 moved = (early * we + late * wl) / (we + wl);\n" \
    "  vec2 fit = f.z < b.z ? f.zw : b.zw;\n" \
    "  float trust = 1.0 - smoothstep(doubt.x, doubt.y, fit.x) * smoothstep(0.4, 0.8, fit.x / max(fit.y, 1e-4));\n" \
    "  if (trust < 0.999) moved = mix(mix(texture(before, uv * scale).rgb, texture(after, uv * scale).rgb, phase), moved, trust);\n" \
    "  result = shown(moved); }\n"
