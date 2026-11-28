// GLSL shared by picture quality mode's two draws: the layer copy (decoder frames, external textures,
// layer_copy.cpp) and the picture layer (frames a software decoder made, 2D textures, video_layer.cpp).
#pragma once

// Monochrome film (the plugins tab) in place of the saturation: the film's weights per channel; saturated
// colours lifted by chroma (warm ones more), so reds and greens of one luminance stay apart; an S curve
// around a pivot (mono_tone.y: the exponent that takes the pivot to 0.5), the black point and paper white; then grain, strongest in the midtones, in cells of
// mono_grain.y output pixels, a new pattern each draw (mono_grain.z). Grain follows the output pixel, so
// each eye of a stereo pair has its own, as two strips of film would.
// color_grade.gdshaderinc holds the same arithmetic.
#define MONO_GLSL \
    "uniform bool mono; uniform vec4 mono_weights; uniform vec4 mono_tone; uniform vec3 mono_grain;\n" \
    "float film_hash(vec2 p) { uvec2 q = uvec2(p) * uvec2(1597334673u, 3812015801u);\n" \
    "  return float((q.x ^ q.y) * 1597334673u) * (1.0 / 4294967296.0); }\n" \
    "float film_noise(vec2 p) { vec2 i = floor(p), f = p - i; f = f * f * (3.0 - 2.0 * f);\n" \
    "  return mix(mix(film_hash(i), film_hash(i + vec2(1.0, 0.0)), f.x), mix(film_hash(i + vec2(0.0, 1.0)), film_hash(i + vec2(1.0)), f.x), f.y); }\n" \
    "vec3 film(vec3 c) { float y = dot(c, mono_weights.rgb);\n" \
    "  float chroma = max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b));\n" \
    "  y = clamp(y + mono_weights.a * chroma * (0.6 + 0.4 * clamp(c.r - c.b, -1.0, 1.0)), 0.0, 1.0);\n" \
    "  float t = pow(y, mono_tone.y), s = pow(t, mono_tone.x); y = pow(s / max(s + pow(1.0 - t, mono_tone.x), 1e-5), 1.0 / mono_tone.y);\n" \
    "  y = clamp((y - mono_tone.z) / max(1.0 - mono_tone.z, 1e-3), 0.0, 1.0) * mono_tone.w;\n" \
    "  if (mono_grain.x > 0.0) y += mono_grain.x * (film_noise(gl_FragCoord.xy / max(mono_grain.y, 1.0) + mono_grain.z * vec2(37.0, 17.0)) - 0.5)\n" \
    "    * (0.35 + 2.6 * y * (1.0 - y));\n" \
    "  return vec3(clamp(y, 0.0, 1.0)); }\n"

// The player's colour grade (color_grade.gdshaderinc holds the same arithmetic).
#define GRADE_GLSL \
    MONO_GLSL \
    "uniform bool graded; uniform bool curved; uniform vec3 gain; uniform vec3 curve; uniform vec3 lift;\n" \
    "uniform float contrast; uniform float saturation;\n" \
    "vec3 grade(vec3 rgb) { if (!graded) return rgb;\n" \
    "  vec3 c = max((rgb * gain - vec3(0.5)) * contrast + vec3(0.5) + lift, vec3(0.0));\n" \
    "  if (curved) c = pow(c, curve);\n" \
    "  if (mono) return film(clamp(c, vec3(0.0), vec3(1.0)));\n" \
    "  return clamp(mix(vec3(dot(c, vec3(0.2126, 0.7152, 0.0722))), c, saturation), vec3(0.0), vec3(1.0)); }\n"

#ifdef __cplusplus
#include <atomic>
// A grade as the plugin passes it: gain, gamma and offset per channel, contrast and saturation (11), then
// monochrome film: 1 when on, the weights of red, green and blue, the chroma lift, the S curve's power,
// the exponent that takes its pivot to 0.5, the black point, paper white, the grain's amount and its cell
// in output pixels (11). A grade of 11
// values alone (the browser's, older callers) has no film.
constexpr int kGradeFloats = 11, kMonoFloats = 11, kGradeAll = kGradeFloats + kMonoFloats;

/** Reads a grade array into [out] (kGradeAll values, the film off when the array has only 11). Returns
 * false for no grade. */
inline bool read_grade(JNIEnv* env, jfloatArray grade, float* out) {
    const jsize length = grade ? env->GetArrayLength(grade) : 0;
    if (length < kGradeFloats) return false;
    for (int index = 0; index < kGradeAll; ++index) out[index] = 0.0f;
    env->GetFloatArrayRegion(grade, 0, length >= kGradeAll ? kGradeAll : kGradeFloats, out);
    return true;
}

/** Monochrome film's uniforms in [program] (in use) from a grade of kGradeAll values, or off (null). */
inline void set_mono(GLuint program, const float* grade) {
    static std::atomic<unsigned> draws{0};
    const bool on = grade && grade[kGradeFloats] > 0.5f;
    glUniform1i(glGetUniformLocation(program, "mono"), on ? 1 : 0);
    if (!on) return;
    const float* m = grade + kGradeFloats;
    glUniform4f(glGetUniformLocation(program, "mono_weights"), m[1], m[2], m[3], m[4]);
    glUniform4f(glGetUniformLocation(program, "mono_tone"), m[5], m[6], m[7], m[8]);
    glUniform3f(glGetUniformLocation(program, "mono_grain"), m[9], m[10], static_cast<float>(draws.fetch_add(1) % 997u));
}
#endif

// The part of each eye's picture the head faces: centre and half size in eye UV, eyes across and down,
// 1 when longitude wraps. A zero size means the whole picture.
#define WINDOW_GLSL \
    "uniform vec4 window; uniform vec3 eyes;\n" \
    "float window_weight(vec2 uv, float rim) { if (window.z <= 0.0) return 1.0;\n" \
    "  vec2 away = fract(uv * eyes.xy) - window.xy;\n" \
    "  if (eyes.z > 0.5) away.x = fract(away.x + 0.5) - 0.5;\n" \
    "  return 1.0 - smoothstep(0.7, 1.0, length(away / window.zw) / rim); }\n"

// FSR 1 EASU (AMD FidelityFX, MIT) after a declaration of vec3 tap(vec2 cell, vec2 offset), which reads
// the source pixel at cell + offset, with uniform vec2 source (its size), in vec2 uv and out vec4 result.
#define EASU_GLSL \
    "float luma(vec3 c) { return c.b * 0.5 + (c.r * 0.5 + c.g); }\n" \
    "void edge(inout vec2 dir, inout float len, float w, float lA, float lB, float lC, float lD, float lE) {\n" \
    "  float dirX = lD - lB;\n" \
    "  float lenX = clamp(abs(dirX) / max(max(abs(lD - lC), abs(lC - lB)), 1e-5), 0.0, 1.0);\n" \
    "  dir.x += dirX * w; len += lenX * lenX * w;\n" \
    "  float dirY = lE - lA;\n" \
    "  float lenY = clamp(abs(dirY) / max(max(abs(lE - lC), abs(lC - lA)), 1e-5), 0.0, 1.0);\n" \
    "  dir.y += dirY * w; len += lenY * lenY * w; }\n" \
    "void kernel(inout vec3 colour, inout float weight, vec2 offset, vec2 dir, vec2 len, float lobe, float clip, vec3 c) {\n" \
    "  vec2 v = vec2(offset.x * dir.x + offset.y * dir.y, offset.x * -dir.y + offset.y * dir.x) * len;\n" \
    "  float d2 = min(dot(v, v), clip);\n" \
    "  float wB = 0.4 * d2 - 1.0, wA = lobe * d2 - 1.0;\n" \
    "  wB *= wB; wA *= wA; wB = 1.5625 * wB - 0.5625;\n" \
    "  float w = wB * wA; colour += c * w; weight += w; }\n" \
    "void main() {\n" \
    "  if (window_weight(uv, 1.05) <= 0.0) { result = vec4(0.0); return; }\n" \
    "  vec2 at = uv * source - 0.5; vec2 cell = floor(at); vec2 pp = at - cell;\n" \
    "  vec3 b = tap(cell, vec2(0.0, -1.0)), c = tap(cell, vec2(1.0, -1.0));\n" \
    "  vec3 e = tap(cell, vec2(-1.0, 0.0)), f = tap(cell, vec2(0.0, 0.0)), g = tap(cell, vec2(1.0, 0.0)), h = tap(cell, vec2(2.0, 0.0));\n" \
    "  vec3 i = tap(cell, vec2(-1.0, 1.0)), j = tap(cell, vec2(0.0, 1.0)), k = tap(cell, vec2(1.0, 1.0)), l = tap(cell, vec2(2.0, 1.0));\n" \
    "  vec3 n = tap(cell, vec2(0.0, 2.0)), o = tap(cell, vec2(1.0, 2.0));\n" \
    "  float bL = luma(b), cL = luma(c), eL = luma(e), fL = luma(f), gL = luma(g), hL = luma(h);\n" \
    "  float iL = luma(i), jL = luma(j), kL = luma(k), lL = luma(l), nL = luma(n), oL = luma(o);\n" \
    "  vec2 dir = vec2(0.0); float len = 0.0;\n" \
    "  edge(dir, len, (1.0 - pp.x) * (1.0 - pp.y), bL, eL, fL, gL, jL);\n" \
    "  edge(dir, len, pp.x * (1.0 - pp.y), cL, fL, gL, hL, kL);\n" \
    "  edge(dir, len, (1.0 - pp.x) * pp.y, fL, iL, jL, kL, nL);\n" \
    "  edge(dir, len, pp.x * pp.y, gL, jL, kL, lL, oL);\n" \
    "  float dirR = dot(dir, dir);\n" \
    "  if (dirR < 1.0 / 32768.0) dir = vec2(1.0, 0.0); else dir *= inversesqrt(dirR);\n" \
    "  len = len * 0.5; len *= len;\n" \
    "  float stretch = dot(dir, dir) / max(abs(dir.x), abs(dir.y));\n" \
    "  vec2 len2 = vec2(1.0 + (stretch - 1.0) * len, 1.0 - 0.5 * len);\n" \
    "  float lobe = 0.5 + (0.21 - 0.5) * len; float clip = 1.0 / lobe;\n" \
    "  vec3 low = min(min(f, g), min(j, k)), high = max(max(f, g), max(j, k));\n" \
    "  vec3 colour = vec3(0.0); float weight = 0.0;\n" \
    "  kernel(colour, weight, vec2(0.0, -1.0) - pp, dir, len2, lobe, clip, b);\n" \
    "  kernel(colour, weight, vec2(1.0, -1.0) - pp, dir, len2, lobe, clip, c);\n" \
    "  kernel(colour, weight, vec2(-1.0, 1.0) - pp, dir, len2, lobe, clip, i);\n" \
    "  kernel(colour, weight, vec2(0.0, 1.0) - pp, dir, len2, lobe, clip, j);\n" \
    "  kernel(colour, weight, vec2(0.0, 0.0) - pp, dir, len2, lobe, clip, f);\n" \
    "  kernel(colour, weight, vec2(-1.0, 0.0) - pp, dir, len2, lobe, clip, e);\n" \
    "  kernel(colour, weight, vec2(1.0, 1.0) - pp, dir, len2, lobe, clip, k);\n" \
    "  kernel(colour, weight, vec2(2.0, 1.0) - pp, dir, len2, lobe, clip, l);\n" \
    "  kernel(colour, weight, vec2(2.0, 0.0) - pp, dir, len2, lobe, clip, h);\n" \
    "  kernel(colour, weight, vec2(1.0, 0.0) - pp, dir, len2, lobe, clip, g);\n" \
    "  kernel(colour, weight, vec2(1.0, 2.0) - pp, dir, len2, lobe, clip, o);\n" \
    "  kernel(colour, weight, vec2(0.0, 2.0) - pp, dir, len2, lobe, clip, n);\n" \
    "  result = vec4(min(high, max(low, colour / weight)), 1.0); }\n"

// Edge-preserving smoothing against compression noise, before any enlargement or sharpening: the eight
// neighbours a step away count by how close their colour is to the pixel's (tolerance: the squared colour
// distance that weighs 1/e), so flat areas even out and lines keep their edge. After a declaration of
// vec3 near(vec2 offset), the source that many steps from this pixel.
#define DENOISE_GLSL \
    "vec3 denoised(float tolerance) { vec3 c = near(vec2(0.0)); vec3 sum = c; float total = 1.0;\n" \
    "  for (int y = -1; y <= 1; ++y) for (int x = -1; x <= 1; ++x) { if (x == 0 && y == 0) continue;\n" \
    "    vec3 n = near(vec2(float(x), float(y))); vec3 d = n - c;\n" \
    "    float w = exp(-dot(d, d) / tolerance) * (x != 0 && y != 0 ? 0.7 : 1.0);\n" \
    "    sum += n * w; total += w; }\n" \
    "  return sum / total; }\n"

// FSR 1 RCAS on a pixel and its four neighbours; boost adds the pixel's difference from them unbounded.
#define RCAS_GLSL \
    "vec3 rcas(vec3 e, vec3 b, vec3 d, vec3 f, vec3 h, float amount, float boost) {\n" \
    "  vec3 low = min(min(b, d), min(f, h)), high = max(max(b, d), max(f, h));\n" \
    "  vec3 hit_low = low / max(4.0 * high, vec3(1e-5)), hit_high = (1.0 - high) / min(4.0 * low - 4.0, vec3(-1e-5));\n" \
    "  vec3 lobes = max(-hit_low, hit_high);\n" \
    "  float lobe = max(-0.1875, min(max(lobes.r, max(lobes.g, lobes.b)), 0.0)) * amount;\n" \
    "  vec3 sharp = (lobe * (b + d + f + h) + e) / (4.0 * lobe + 1.0);\n" \
    "  return clamp(sharp + (e - 0.25 * (b + d + f + h)) * boost, 0.0, 1.0); }\n"
