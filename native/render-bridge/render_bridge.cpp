#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl31.h>
#include <GLES2/gl2ext.h>
#include <android/bitmap.h>
#include <android/hardware_buffer.h>
#include <android/hardware_buffer_jni.h>
#include <jni.h>
#include <android/log.h>
#include <sys/system_properties.h>
#include <cstdio>
#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <chrono>
#include <cstring>
#include <limits>
#include <map>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include "../rvm/photo_depth.h"
#include "../rvm/photo_rotation.h"
#include <unordered_map>
#include <vector>
#include "frame_gpu_timing.h"

namespace {
void check_gl(const char* operation) {
    const auto error = glGetError();
    if (error == GL_NO_ERROR) return;
    char message[160];
    std::snprintf(message, sizeof(message), "%s: GL error 0x%04x", operation, error);
    throw std::runtime_error(message);
}
// Errors raised earlier on the shared context by other GL users (Godot, MPV) are not the
// bridge's: report and clear them so the bridge's own checks see only its own calls.
void drain_gl(const char* operation) {
    for (int i = 0; i < 8; ++i) {
        const auto error = glGetError();
        if (error == GL_NO_ERROR) return;
        __android_log_print(ANDROID_LOG_WARN, "QuestRenderBridge", "Pending GL error 0x%04x before %s", error, operation);
    }
}
// Touch only private objects and unit zero; restore Godot's actual GL state.
struct State final {
    GLint program, vao, draw_fbo, read_fbo, active, tex2d, oes, sampler, pack, unpack;
    GLint viewport[4];
    GLint pack_alignment, pack_row_length, pack_skip_rows, pack_skip_pixels;
    GLint unpack_alignment, unpack_row_length, unpack_skip_rows, unpack_skip_pixels, unpack_image_height, unpack_skip_images;
    GLboolean mask[4];
    static constexpr std::array<GLenum, 10> toggles{{GL_BLEND, GL_DEPTH_TEST, GL_CULL_FACE, GL_SCISSOR_TEST,
        GL_STENCIL_TEST, GL_DITHER, GL_RASTERIZER_DISCARD, GL_SAMPLE_ALPHA_TO_COVERAGE, GL_SAMPLE_COVERAGE,
        GL_POLYGON_OFFSET_FILL}};
    std::array<GLboolean, toggles.size()> enabled;
    State() {
        glGetIntegerv(GL_CURRENT_PROGRAM, &program); glGetIntegerv(GL_VERTEX_ARRAY_BINDING, &vao);
        glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &draw_fbo); glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &read_fbo);
        glGetIntegerv(GL_ACTIVE_TEXTURE, &active); glActiveTexture(GL_TEXTURE0);
        glGetIntegerv(GL_TEXTURE_BINDING_2D, &tex2d); glGetIntegerv(GL_TEXTURE_BINDING_EXTERNAL_OES, &oes);
        glGetIntegerv(GL_SAMPLER_BINDING, &sampler); glGetIntegerv(GL_PIXEL_PACK_BUFFER_BINDING, &pack);
        glGetIntegerv(GL_PIXEL_UNPACK_BUFFER_BINDING, &unpack);
        glGetIntegerv(GL_VIEWPORT, viewport); glGetBooleanv(GL_COLOR_WRITEMASK, mask);
        glGetIntegerv(GL_PACK_ALIGNMENT, &pack_alignment); glGetIntegerv(GL_PACK_ROW_LENGTH, &pack_row_length);
        glGetIntegerv(GL_PACK_SKIP_ROWS, &pack_skip_rows); glGetIntegerv(GL_PACK_SKIP_PIXELS, &pack_skip_pixels);
        glGetIntegerv(GL_UNPACK_ALIGNMENT, &unpack_alignment); glGetIntegerv(GL_UNPACK_ROW_LENGTH, &unpack_row_length);
        glGetIntegerv(GL_UNPACK_SKIP_ROWS, &unpack_skip_rows); glGetIntegerv(GL_UNPACK_SKIP_PIXELS, &unpack_skip_pixels);
        glGetIntegerv(GL_UNPACK_IMAGE_HEIGHT, &unpack_image_height); glGetIntegerv(GL_UNPACK_SKIP_IMAGES, &unpack_skip_images);
        for (size_t i = 0; i < toggles.size(); ++i) enabled[i] = glIsEnabled(toggles[i]);
        glBindSampler(0, 0); glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
        glPixelStorei(GL_PACK_ALIGNMENT, 1); glPixelStorei(GL_PACK_ROW_LENGTH, 0);
        glPixelStorei(GL_PACK_SKIP_ROWS, 0); glPixelStorei(GL_PACK_SKIP_PIXELS, 0);
        glPixelStorei(GL_UNPACK_ALIGNMENT, 1); glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
        glPixelStorei(GL_UNPACK_SKIP_ROWS, 0); glPixelStorei(GL_UNPACK_SKIP_PIXELS, 0);
        glPixelStorei(GL_UNPACK_IMAGE_HEIGHT, 0); glPixelStorei(GL_UNPACK_SKIP_IMAGES, 0);
        glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
        for (auto toggle : toggles) glDisable(toggle);
    }
    ~State() {
        glUseProgram(program); glBindVertexArray(vao);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, draw_fbo); glBindFramebuffer(GL_READ_FRAMEBUFFER, read_fbo);
        glViewport(viewport[0], viewport[1], viewport[2], viewport[3]); glColorMask(mask[0], mask[1], mask[2], mask[3]);
        for (size_t i = 0; i < toggles.size(); ++i) { if (enabled[i]) glEnable(toggles[i]); else glDisable(toggles[i]); }
        glBindBuffer(GL_PIXEL_PACK_BUFFER, pack); glBindBuffer(GL_PIXEL_UNPACK_BUFFER, unpack);
        glPixelStorei(GL_PACK_ALIGNMENT, pack_alignment); glPixelStorei(GL_PACK_ROW_LENGTH, pack_row_length);
        glPixelStorei(GL_PACK_SKIP_ROWS, pack_skip_rows); glPixelStorei(GL_PACK_SKIP_PIXELS, pack_skip_pixels);
        glPixelStorei(GL_UNPACK_ALIGNMENT, unpack_alignment); glPixelStorei(GL_UNPACK_ROW_LENGTH, unpack_row_length);
        glPixelStorei(GL_UNPACK_SKIP_ROWS, unpack_skip_rows); glPixelStorei(GL_UNPACK_SKIP_PIXELS, unpack_skip_pixels);
        glPixelStorei(GL_UNPACK_IMAGE_HEIGHT, unpack_image_height); glPixelStorei(GL_UNPACK_SKIP_IMAGES, unpack_skip_images);
        glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, tex2d); glBindTexture(GL_TEXTURE_EXTERNAL_OES, oes);
        glBindSampler(0, sampler); glActiveTexture(active);
    }
};
constexpr const char* vertex = R"(#version 300 es
out highp vec2 uv;
void main() {
    vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
    uv = p; gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
})";
constexpr const char* copy_fragment = R"(#version 300 es
#extension GL_OES_EGL_image_external_essl3 : require
precision highp float;
uniform samplerExternalOES source;
uniform mat4 transform;
in highp vec2 uv;
out vec4 result;
void main() { result = vec4(texture(source, (transform * vec4(uv.x, 1.0-uv.y, 0.0, 1.0)).xy).rgb, 1.0); }
)";
// Model input: each output pixel averages a 4x4 grid over its source footprint (eye UV).
// A single bilinear tap at 6-12x decimation aliases fine texture into noise that flickers
// frame to frame; the box average matches the area-resampled offline reference.
// Outside the content rectangle (letterbox) the input is black, or with edge_fill (2D->3D) the
// nearest content edge: ZipDepth reads a black band as a near object, which compresses the
// picture's relief and adds a false near line along its edge.
constexpr const char* scale_fragment = R"(#version 300 es
precision highp float;
uniform sampler2D source;
uniform vec4 content_rect;
uniform vec4 eye_rect;
uniform vec2 eye_size;
uniform vec2 footprint;
uniform bool edge_fill;
in highp vec2 uv;
out vec4 result;
vec3 tap(vec2 p) {
    p=clamp(p,vec2(0.5)/eye_size,vec2(1.0)-vec2(0.5)/eye_size);
    return texture(source,eye_rect.xy+p*eye_rect.zw).rgb;
}
void main() {
    vec2 p = (uv-content_rect.xy)/content_rect.zw;
    if (edge_fill) p=clamp(p,vec2(0.0),vec2(1.0));
    else if (any(lessThan(p,vec2(0.0))) || any(greaterThan(p,vec2(1.0)))) { result=vec4(0.0,0.0,0.0,1.0); return; }
    if (max(footprint.x*eye_size.x, footprint.y*eye_size.y) < 1.5) { result=vec4(tap(p),1.0); return; }
    vec3 sum=vec3(0.0);
    for (int j=0;j<4;++j) for (int i=0;i<4;++i) sum+=tap(p+(vec2(float(i),float(j))+0.5)*footprint*0.25-footprint*0.5);
    result=vec4(sum/16.0,1.0);
})";
// Same footprint average on the decoder's own image (YUV through samplerExternalOES); uv_scale
// maps the visible frame into a buffer that may be padded.
constexpr const char* scale_oes_fragment = R"(#version 300 es
#extension GL_OES_EGL_image_external_essl3 : require
precision highp float;
uniform samplerExternalOES source;
uniform vec4 content_rect;
uniform vec4 eye_rect;
uniform vec2 eye_size;
uniform vec2 footprint;
uniform vec2 uv_scale;
uniform bool edge_fill;
in highp vec2 uv;
out vec4 result;
vec3 tap(vec2 p) {
    p=clamp(p,vec2(0.5)/eye_size,vec2(1.0)-vec2(0.5)/eye_size);
    return texture(source,(eye_rect.xy+p*eye_rect.zw)*uv_scale).rgb;
}
void main() {
    vec2 p = (uv-content_rect.xy)/content_rect.zw;
    if (edge_fill) p=clamp(p,vec2(0.0),vec2(1.0));
    else if (any(lessThan(p,vec2(0.0))) || any(greaterThan(p,vec2(1.0)))) { result=vec4(0.0,0.0,0.0,1.0); return; }
    if (max(footprint.x*eye_size.x, footprint.y*eye_size.y) < 1.5) { result=vec4(tap(p),1.0); return; }
    vec3 sum=vec3(0.0);
    for (int j=0;j<4;++j) for (int i=0;i<4;++i) sum+=tap(p+(vec2(float(i),float(j))+0.5)*footprint*0.25-footprint*0.5);
    result=vec4(sum/16.0,1.0);
})";
constexpr const char* copy_2d_fragment = R"(#version 300 es
precision highp float;
uniform sampler2D source;
in highp vec2 uv; out vec4 result;
void main() { result = vec4(texture(source, uv).rgb, 1.0); }
)";
// Canonical decoder rows, unlike the Android SurfaceTexture transform above.
constexpr const char* freeze_oes_fragment = R"(#version 300 es
#extension GL_OES_EGL_image_external_essl3 : require
precision highp float;
uniform samplerExternalOES source;
uniform vec2 uv_scale;
in highp vec2 uv; out vec4 result;
void main() { result = vec4(texture(source, uv * uv_scale).rgb, 1.0); }
)";
// Realtime 2D->3D stereo, ported from PTMediaServer's soft_shift (offline/two_dvr_gpu.py): forward
// warp with a z-buffer, disocclusion holes filled from the inverse warp, a background-side rim
// cleanup, a seam blend that never smears the occluder, and the in-body sliver cleanup.
// Everything that depends only on the near map (z-buffer winners, holes, rim, blend gate, sliver
// redirects) is built by compute into `map` when the map changes (~10 Hz); every video frame then
// costs one light fragment pass. map texel: x = source x offset, y = z-buffer near (-1 hole),
// z = blend gate (2 = none), w = sliver redirect offset (0 = none).
constexpr const char* warp_common = R"(#version 310 es
precision highp float; precision highp int;
layout(std430, binding = 0) buffer Keys { highp uint keys[]; };
uniform highp sampler2D near_map; // R8 pair mask; the left half is read
uniform ivec2 size;               // eye width/height
uniform ivec2 model;              // model width/height
uniform vec4 content;             // model = content.xy + eye_uv * content.zw
uniform vec2 shift;               // x: half the maximum parallax in px, y: screen-plane near
uniform int text_count;
uniform vec4 text_weights0;
uniform vec4 text_weights1;
uniform vec4 text_regions[8]; // source UV x0,y0,x1,y1; independent of the near-map grid
float text_weight(vec2 uv) {
    vec2 feather = vec2(2.0) / vec2(size);
    float guard = abs(shift.x) * max(shift.y, 1.0-shift.y) / float(size.x);
    float weight=0.0;
    for(int i=0;i<8;++i) {
        if(i>=text_count)break;
        vec4 r=text_regions[i]+vec4(-guard,-feather.y,guard,feather.y);
        vec2 d=min(uv-r.xy,r.zw-uv);
        vec2 a=smoothstep(vec2(0.0),feather,d);
        float opacity=i<4 ? text_weights0[i] : text_weights1[i-4];
        weight=max(weight,a.x*a.y*opacity);
    }
    return weight;
}
float tap(int x, int y) { return texelFetch(near_map, ivec2(x, y), 0).r; }
// Stills (split): winners are snapped from the unlimited near map. The gradient limit is there for
// the inverse lookup of holes; at high strength it widens a depth step into a ramp wider than a table
// leg, and snapping that ramp cut it into a staircase of small steps (shards) and carried the
// background beside an arm along with it (a second edge). Holes still read the limited map.
uniform highp sampler2D snap_map; // R8, model size
uniform bool split;
float tap_at(int x, int y, bool snap) { return snap && split ? texelFetch(snap_map, ivec2(x, y), 0).r : tap(x, y); }
// Continuous threshold (cont): the snap window's low/high per model texel (window_map, fill_window_fragment
// over the snap source) taken bilinearly like the near itself, so a contour is a curve and not 5 px
// stairs of the model grid. Position stretch only; rim cleanup marks re-sourced winners as holes.
uniform highp sampler2D window_map;
uniform bool cont;
uniform int position;
// PTMediaServer _near_at: bilinear between model centres inside the content; with snap, the
// toggle sharpen picks the nearer of the local horizontal min/max so contours become hard edges.
float near_at(int x, int y, bool snap) {
    vec2 lo = ceil(content.xy * vec2(model) - 0.5);
    vec2 hi = max(lo, floor((content.xy + content.zw) * vec2(model) - 0.5));
    vec2 p = clamp((content.xy + (vec2(x, y) + 0.5) / vec2(size) * content.zw) * vec2(model) - 0.5, lo, hi);
    ivec2 a = ivec2(floor(p)); ivec2 b = min(a + 1, ivec2(hi)); vec2 f = p - vec2(a);
    float n = mix(mix(tap_at(a.x, a.y, snap), tap_at(b.x, a.y, snap), f.x), mix(tap_at(a.x, b.y, snap), tap_at(b.x, b.y, snap), f.x), f.y);
    if (snap && cont) {
        vec2 w00 = texelFetch(window_map, a, 0).rg, w10 = texelFetch(window_map, ivec2(b.x, a.y), 0).rg;
        vec2 w01 = texelFetch(window_map, ivec2(a.x, b.y), 0).rg, w11 = texelFetch(window_map, b, 0).rg;
        vec2 lh = mix(mix(w00, w10, f.x), mix(w01, w11, f.x), f.y);
        float l = min(lh.x, n), h = max(lh.y, n);
        n = (n - l) >= (h - n) ? h : l;
    } else if (snap) {
    int win = max(1, int(ceil(6.0 * content.z * float(model.x) / float(size.x))));
    float l = n, h = n;
    for (int d = -win; d <= win; ++d) {
        int xx = clamp(a.x + d, int(lo.x), int(hi.x));
        float u = tap_at(xx, a.y, true), v = tap_at(xx, b.y, true);
        l = min(l, min(u, v)); h = max(h, max(u, v));
    }
    n = (n - l) >= (h - n) ? h : l;
    }
    return mix(n,shift.y,text_weight((vec2(x,y)+0.5)/vec2(size)));
}
uint key_at(int x, int y) { return keys[y * 2 * size.x + x]; }
float near_of(uint k) { return k == 0u ? -1.0 : float((k >> 12) - 1u) / 524287.0; }
)";
constexpr const char* warp_clear = R"(
layout(local_size_x = 256) in;
uniform int count;
void main() { int i = int(gl_GlobalInvocationID.x); if (i < count) keys[i] = 0u; }
)";
// fw_zbuf + fw_color in one pass: the key packs priority (near) above the source column, so the
// atomic maximum is both the z-test and the winner.
constexpr const char* warp_scatter = R"(
layout(local_size_x = 8, local_size_y = 8) in;
void main() {
    ivec2 p = ivec2(gl_GlobalInvocationID.xy);
    if (p.x >= size.x || p.y >= size.y) return;
    float n = near_at(p.x, p.y, true);
    uint key = ((uint(n * 524287.0 + 0.5) + 1u) << 12) | uint(p.x);
    for (int eye = 0; eye < 2; ++eye) {
        float sgn = eye == 0 ? 1.0 : -1.0;
        int tx = int(floor(float(p.x) + (n - shift.y) * shift.x * sgn + 0.5));
        if (tx >= 0 && tx < size.x) atomicMax(keys[p.y * 2 * size.x + eye * size.x + tx], key);
    }
}
)";
// The rim test, shared by the keep pass and classify.
constexpr const char* warp_rim = R"(
uniform int rim;     // background-side rim cleanup width (fw_hole_from_inv)
// Stills only. A stretched band (gradient-limited ramp) leaves 1-2 px gaps between winners; the
// inverse lookup there uses the unsnapped near, reads other columns and shreds hair and text into
// streaks. Bridged pixels (gaps of at most two columns) instead take their source column from the
// kept winners either side: interpolated across one surface, the far side's edge texel across a
// depth step (gate = -3).
uniform int bridge;
// Bridged stills (see warp_keep): two bit planes of the pair, 32 columns to a word: 0 wide holes,
// 1 kept winners.
layout(std430, binding = 1) buffer Kept { highp uint plane_bits[]; };
int row_words() { return (2 * size.x + 31) / 32; }
int plane_row(int plane, int y) { return (plane * size.y + y) * row_words(); }
uint span(int a, int b) { return (b >= 31 ? 0xffffffffu : (1u << uint(b + 1)) - 1u) & ~((1u << uint(a)) - 1u); }
bool any_set(int plane, int y, int a, int b) { // a column in a..b set
    int base = plane_row(plane, y);
    for (int w = a >> 5; a <= b && w <= (b >> 5); ++w)
        if ((plane_bits[base + w] & span(max(a - w * 32, 0), min(b - w * 32, 31))) != 0u) return true;
    return false;
}
int last_set(int plane, int y, int a, int b) { // the highest set column in a..b, -1 for none
    int base = plane_row(plane, y);
    for (int w = b >> 5; a <= b && w >= (a >> 5); --w) {
        uint m = plane_bits[base + w] & span(max(a - w * 32, 0), min(b - w * 32, 31));
        if (m != 0u) return w * 32 + findMSB(m);
    }
    return -1;
}
int first_set(int plane, int y, int a, int b) { // the lowest set column in a..b, -1 for none
    int base = plane_row(plane, y);
    for (int w = a >> 5; a <= b && w <= (b >> 5); ++w) {
        uint m = plane_bits[base + w] & span(max(a - w * 32, 0), min(b - w * 32, 31));
        if (m != 0u) return w * 32 + findLSB(m);
    }
    return -1;
}
bool kept_at(int x, int y) { return ((plane_bits[plane_row(1, y) + (x >> 5)] >> uint(x & 31)) & 1u) != 0u; }
bool wide_hole(int x, int y, int lo, int hi) {
    if (key_at(x, y) != 0u) return false;
    int n = 1;
    for (int s = 1; s <= 2 && x - s >= lo && key_at(x - s, y) == 0u; ++s) ++n;
    for (int s = 1; s <= 2 && x + s < hi && key_at(x + s, y) == 0u; ++s) ++n;
    return n >= 3;
}
bool rim_at(int x, int y, int eye, int lo, int hi, uint k) {
    if (k == 0u || rim <= 0 || near_of(k) >= 0.5) return false;
    int dir = eye == 0 ? 1 : -1; // toward the gap
    for (int s = 1; s <= rim; ++s) {
        int nx = x + dir * s;
        if (nx < lo || nx >= hi) break;
        // Bridged stills clean the rim of disocclusions only, not of every stretch gap.
        if (bridge != 0 ? wide_hole(nx, y, lo, hi) : key_at(nx, y) == 0u) return true;
    }
    return false;
}
)";
// Bridged stills, one invocation per 32 columns, run twice (stage 0: wide holes, 1: kept winners).
// Classify's rim test walked up to `rim` columns per texel, re-run at every step of the bridge
// search: the still map's cost grew with width cubed (0.3-0.47 s for a 3547-wide eye on Quest 3).
// With the planes, the rim test (rim_at) is a bit-range test and the bridge search findMSB/findLSB.
constexpr const char* warp_keep = R"(
layout(local_size_x = 64) in;
uniform int stage;
void main() {
    int words = row_words(), w = int(gl_GlobalInvocationID.x), y = int(gl_GlobalInvocationID.y);
    if (w >= words || y >= size.y) return;
    int W = size.x;
    uint bits = 0u;
    for (int b = 0; b < 32; ++b) {
        int x = w * 32 + b;
        if (x >= 2 * W) break;
        int lo = x < W ? 0 : W, hi = lo + W;
        bool set;
        if (stage == 0) set = wide_hole(x, y, lo, hi);
        else {
            uint k = key_at(x, y);
            // rim_at: a wide hole within `rim` columns toward the gap (right of the left eye's texel).
            bool rimmed = k != 0u && rim > 0 && near_of(k) < 0.5 &&
                (lo == 0 ? any_set(0, y, x + 1, min(x + rim, hi - 1)) : any_set(0, y, max(x - rim, lo), x - 1));
            set = k != 0u && !rimmed;
        }
        if (set) bits |= 1u << uint(b);
    }
    plane_bits[plane_row(stage, y) + w] = bits;
}
)";
constexpr const char* warp_classify = R"(
layout(local_size_x = 8, local_size_y = 8) in;
layout(rgba16f, binding = 0) writeonly uniform highp image2D map;
uniform int fg_win;  // sliver window (fw_fg_bad_local)
void main() {
    ivec2 o = ivec2(gl_GlobalInvocationID.xy);
    int W = size.x;
    if (o.x >= 2 * W || o.y >= size.y) return;
    int eye = o.x / W, ex = o.x - eye * W, lo = eye * W, hi = lo + W;
    uint k = key_at(o.x, o.y);
    float z = near_of(k);
    float src = float(k & 4095u);
    bool inv = bridge != 0 ? !kept_at(o.x, o.y) : (k == 0u || rim_at(o.x, o.y, eye, lo, hi, k));
    if (inv) {
        float n = near_at(ex, o.y, false);
        src = clamp(float(ex) + (eye == 0 ? -1.0 : 1.0) * (n - shift.y) * shift.x, 0.0, float(W - 1));
    }
    float gate = 2.0;
    if (k == 0u) {
        float nmin = 2.0, nmax = -1.0;
        for (int dy = -2; dy <= 2; ++dy) {
            int ny = clamp(o.y + dy, 0, size.y - 1);
            for (int dx = -3; dx <= 3; ++dx) {
                int nx = o.x + dx;
                if (nx < lo || nx >= hi) continue;
                uint nk = key_at(nx, ny);
                if (nk != 0u) { float nr = near_of(nk); nmin = min(nmin, nr); nmax = max(nmax, nr); }
            }
        }
        if (nmax - nmin > 0.30) gate = 0.5 * (nmin + nmax);
    }
    float pick = 0.0;
    if (fg_win > 0 && !(k != 0u && z >= 0.5)) {
        int l = -1, r = -1;
        for (int s = 1; s <= fg_win; ++s) {
            int nx = o.x - s; if (nx < lo) break;
            uint nk = key_at(nx, o.y);
            if (nk != 0u && near_of(nk) >= 0.5) { l = nx; break; }
        }
        if (l >= 0) for (int s = 1; s <= fg_win; ++s) {
            int nx = o.x + s; if (nx >= hi) break;
            uint nk = key_at(nx, o.y);
            if (nk != 0u && near_of(nk) >= 0.5) { r = nx; break; }
        }
        if (l >= 0 && r >= 0) pick = float(((o.x - l) <= (r - o.x) ? l : r) - o.x);
    }
    // Only gaps of at most two columns are bridged. A wider run keeps the inverse warp above: the
    // still's near map is gradient-limited, so that lookup is monotone and stretches the background.
    // Bridging wide runs as well held one texel per row across them: horizontal streaks whose ends
    // stepped with the snapped near map's rows (user-visible jaggies beside every occluder).
    if (bridge != 0 && inv) {
        int l = last_set(1, o.y, max(lo, o.x - 3), o.x - 1);
        int r = first_set(1, o.y, o.x + 1, min(hi - 1, o.x + 3));
        if (l >= 0 && r >= 0 && r - l - 1 <= 2) {
            uint kl = key_at(l, o.y), kr = key_at(r, o.y);
            float sl = float(kl & 4095u), sr = float(kr & 4095u), zl = near_of(kl), zr = near_of(kr);
            if (abs(zl - zr) <= 0.08) src = mix(sl, sr, float(o.x - l) / float(r - l));
            // Across a step, hold the far side's texel two columns clear of its edge: mirroring
            // or the 1:1 inverse warp copy letters or the occluder's contour into the gap.
            else src = zl <= zr ? sl - 2.0 : sr + 2.0;
            src = clamp(src, 0.0, float(W - 1));
            gate = -3.0; pick = 0.0;
        }
    }
    // Position stretch: a background winner the rim cleanup re-sourced counts as hole for fill_run.
    if (position != 0 && inv) z = -1.0;
    imageStore(map, o, vec4(src - float(ex), z, gate, pick));
}
)";
// Fill gaps, backward map (the default; debug.vrpp.fill.v2 0 restores the compute warp): the same map as clear + scatter + classify from two
// fragment passes, no compute, atomics or 4 bytes per pair texel of keys. Every pair texel solves
// x + s*(snapped near(x) - convergence)*k = its column by fixed-point steps that start at the nearest
// near within reach, so a converged x is the z-buffer winner (the forward warp's own rounding: within
// 0.75 px). What stays unplaced is a disocclusion and takes the classify's hole source, the inverse
// warp of the unsnapped map; its blend gate is left to the frame pass (gate 3). Rim and sliver
// redirects clean up after the forward scatter and are not needed. Offline the pair matches the
// forward warp within 0.014 of 255 on average (research/video_depth_replay/fill_eval.py).
// Pass 1, model size: per model texel the snap window's low/high (near_at) and the highest near within
// the parallax reach, where the search starts.
constexpr const char* fill_window_fragment = R"(#version 300 es
precision highp float; precision highp int;
uniform highp sampler2D near_map; // R8 pair mask; the left half is read
uniform ivec2 model;
uniform vec4 content;
uniform int win;   // near_at's snap window, model columns
uniform int reach; // the parallax reach, model columns
out vec4 result;
float tap(int x, int y) { return texelFetch(near_map, ivec2(x, y), 0).r; }
void main() {
    ivec2 a = ivec2(gl_FragCoord.xy);
    ivec2 lo = ivec2(ceil(content.xy * vec2(model) - 0.5));
    ivec2 hi = max(lo, ivec2(floor((content.xy + content.zw) * vec2(model) - 0.5)));
    int ay = clamp(a.y, lo.y, hi.y), by = min(ay + 1, hi.y);
    float l = 2.0, h = -1.0, f = -1.0;
    for (int d = -win - reach; d <= win + reach; ++d) {
        int xx = clamp(a.x + d, lo.x, hi.x);
        float u = tap(xx, ay), v = tap(xx, by);
        f = max(f, max(u, v));
        if (d >= -win && d <= win) { l = min(l, min(u, v)); h = max(h, max(u, v)); }
    }
    result = vec4(l, h, f, 1.0);
}
)";
// Pass 2, pair size: the map texel (source x offset, near or -1 for a hole, gate, sliver offset 0).
constexpr const char* fill_map_fragment = R"(#version 300 es
precision highp float; precision highp int;
uniform highp sampler2D near_map;
uniform highp sampler2D window; // pass 1
uniform ivec2 size;
uniform ivec2 model;
uniform vec4 content;
uniform vec2 shift;             // x: half the maximum parallax in px, y: screen-plane near
uniform bool cont;              // warp_common's continuous threshold
out vec4 result;
float tap(int x, int y) { return texelFetch(near_map, ivec2(x, y), 0).r; }
// warp_common near_at; a: the model texel whose window applies.
float near_at(int x, int y, bool snap, out ivec2 a) {
    vec2 lo = ceil(content.xy * vec2(model) - 0.5);
    vec2 hi = max(lo, floor((content.xy + content.zw) * vec2(model) - 0.5));
    vec2 p = clamp((content.xy + (vec2(x, y) + 0.5) / vec2(size) * content.zw) * vec2(model) - 0.5, lo, hi);
    a = ivec2(floor(p)); ivec2 b = min(a + 1, ivec2(hi)); vec2 f = p - vec2(a);
    float n = mix(mix(tap(a.x, a.y), tap(b.x, a.y), f.x), mix(tap(a.x, b.y), tap(b.x, b.y), f.x), f.y);
    if (!snap) return n;
    vec2 lh = texelFetch(window, a, 0).rg;
    if (cont) {
        lh = mix(mix(lh, texelFetch(window, ivec2(b.x, a.y), 0).rg, f.x),
                 mix(texelFetch(window, ivec2(a.x, b.y), 0).rg, texelFetch(window, b, 0).rg, f.x), f.y);
        lh = vec2(min(lh.x, n), max(lh.y, n));
    }
    return (n - lh.x) >= (lh.y - n) ? lh.y : lh.x;
}
void main() {
    ivec2 o = ivec2(gl_FragCoord.xy);
    int W = size.x, eye = o.x >= W ? 1 : 0, ex = o.x - eye * W;
    float sgn = eye == 0 ? 1.0 : -1.0;
    ivec2 a;
    float u = near_at(ex, o.y, false, a);
    float x = float(ex) - sgn * (texelFetch(window, a, 0).b - shift.y) * shift.x;
    for (int i = 0; i < 4; ++i) {
        int xi = clamp(int(floor(x + 0.5)), 0, W - 1);
        x = float(ex) - sgn * (near_at(xi, o.y, true, a) - shift.y) * shift.x;
    }
    int xi = clamp(int(floor(x + 0.5)), 0, W - 1);
    float n = near_at(xi, o.y, true, a);
    if (abs(float(xi) + sgn * (n - shift.y) * shift.x - float(ex)) <= 0.75) {
        result = vec4(float(xi - ex), n, 2.0, 0.0);
        return;
    }
    float src = clamp(float(ex) - sgn * (u - shift.y) * shift.x, 0.0, float(W - 1));
    result = vec4(src - float(ex), -1.0, 3.0, 0.0);
}
)";
// Position stretch (the default; debug.vrpp.fill.position 0 for plain holes), two map passes after the fill:
// holes take background only, by position. 1 (fill_run_fragment): a hole texel finds the nearest winner
// either side in its row; across a depth step its source runs from the far-side winner's column to the
// column beside the occluder in the source, within one surface it interpolates between the two ends.
// 2 (fill_rows_fragment): those offsets are averaged over hole texels 2*rows+1 rows down the column and
// clamped back into the texel's own background span, so rows agree without reading the occluder.
// Map texels after pass 1: holes (x offset, -2 - far near, span low, span high); pass 2 restores
// (offset, far near, 2, 0), a plain winner for the frame pass. Offline: fill_v3.py position_pair.
constexpr const char* fill_run_fragment = R"(#version 300 es
precision highp float; precision highp int;
uniform highp sampler2D map;
uniform ivec2 size;
uniform int reach;
out vec4 result;
void main() {
    ivec2 o = ivec2(gl_FragCoord.xy);
    int W = size.x, lo = o.x >= W ? W : 0, hi = lo + W, ex = o.x - lo;
    vec4 m = texelFetch(map, o, 0);
    result = m;
    if (m.y >= 0.0) return;
    int l = -1, r = -1; vec4 ml = vec4(0.0), mr = vec4(0.0);
    for (int d = 1; d <= reach; ++d) {
        int x = o.x - d; if (x < lo) break;
        vec4 q = texelFetch(map, ivec2(x, o.y), 0);
        if (q.y >= 0.0) { l = x; ml = q; break; }
    }
    for (int d = 1; d <= reach; ++d) {
        int x = o.x + d; if (x >= hi) break;
        vec4 q = texelFetch(map, ivec2(x, o.y), 0);
        if (q.y >= 0.0) { r = x; mr = q; break; }
    }
    if (l < 0 || r < 0) return;
    float sl = float(l - lo) + ml.x, sr = float(r - lo) + mr.x;
    bool across = abs(ml.y - mr.y) > 0.08, far_left = ml.y <= mr.y;
    // The occluder's end never passes the far side's start (fill_v3.py position_pair).
    float tl = across && !far_left ? min(sl + 1.0, sr) : sl;
    float tr = across && far_left ? max(sr - 1.0, sl) : sr;
    float s = tl + (tr - tl) * float(o.x - l) / float(r - l);
    result = vec4(s - float(ex), -2.0 - min(ml.y, mr.y), min(tl, tr) - float(ex), max(tl, tr) - float(ex));
}
)";
constexpr const char* fill_rows_fragment = R"(#version 300 es
precision highp float; precision highp int;
uniform highp sampler2D map;
uniform ivec2 size;
uniform int rows;
out vec4 result;
void main() {
    ivec2 o = ivec2(gl_FragCoord.xy);
    vec4 m = texelFetch(map, o, 0);
    result = m;
    if (m.y > -1.5) return;
    float sum = 0.0, n = 0.0;
    for (int dy = -rows; dy <= rows; ++dy) {
        vec4 q = texelFetch(map, ivec2(o.x, clamp(o.y + dy, 0, size.y - 1)), 0);
        if (q.y < -1.5) { sum += q.x; n += 1.0; }
    }
    result = vec4(clamp(sum / n, m.z, m.w), -2.0 - m.y, 2.0, 0.0);
}
)";
// Per frame, one pass: every output texel takes its source colour (winner column, or the inverse
// warp); holes get fw_blend (7x5, the occluder excluded across a depth step) and fw_fg_bad_local
// slivers the colour of their nearest enclosing foreground. Neighbours are resolved through the
// map too, so no intermediate image is written.
constexpr const char* warp_frame_body = R"(
uniform highp sampler2D map;
uniform vec2 uv_scale;
uniform ivec2 size;
uniform int photo_rotation; // Still-only virtual clockwise turns; video always sets zero.
uniform vec2 footprint; // quarter output pixel in source UV when the pair is scaled down, else zero
uniform bool source_alpha_enabled;
uniform sampler2D source_alpha;
uniform vec4 alpha_content;
out vec4 result;
vec4 colour(ivec2 o, vec4 m) {
    int ex = o.x >= size.x ? o.x - size.x : o.x;
    vec2 p = vec2((float(ex) + m.x + 0.5) / float(size.x), (float(o.y) + 0.5) / float(size.y));
    // Map the virtual rotated source back to the unchanged colour texture.
    if (photo_rotation == 1) p = vec2(p.y, 1.0-p.x);
    else if (photo_rotation == 2) p = vec2(1.0)-p;
    else if (photo_rotation == 3) p = vec2(1.0-p.y, p.x);
    float a = 1.0;
    if (source_alpha_enabled) {
        vec2 half_pixel = 0.5 / vec2(textureSize(source_alpha, 0));
        vec2 q = clamp(alpha_content.xy + p * alpha_content.zw, half_pixel, 1.0 - half_pixel);
        a = texture(source_alpha, q).r;
    }
    vec3 rgb = texture(source, p * uv_scale).rgb;
    if (footprint.x > 0.0 || footprint.y > 0.0)
        rgb = 0.25 * (texture(source, (p - footprint) * uv_scale).rgb
            + texture(source, (p + vec2(footprint.x, -footprint.y)) * uv_scale).rgb
            + texture(source, (p + vec2(-footprint.x, footprint.y)) * uv_scale).rgb
            + texture(source, (p + footprint) * uv_scale).rgb);
    return vec4(rgb * a, a);
}
void main() {
    ivec2 o = ivec2(gl_FragCoord.xy);
    // Store each eye in the original orientation, preserving SBS packing. The display's
    // centre roll then turns the photo once while returning disparity to viewer-horizontal.
    if (photo_rotation != 0) {
        int original_width = (photo_rotation % 2 == 1) ? size.y : size.x;
        int eye = o.x / original_width;
        ivec2 p = ivec2(o.x - eye * original_width, o.y);
        if (photo_rotation == 1) p = ivec2(size.x-1-p.y, p.x);
        else if (photo_rotation == 2) p = size-ivec2(1)-p;
        else if (photo_rotation == 3) p = ivec2(p.y, size.y-1-p.x);
        o = p + ivec2(eye * size.x, 0);
    }
    vec4 m = texelFetch(map, o, 0);
    if (m.z < -2.5) {
        // Bridged still pixels: mean over bridged neighbours (5x9), so one row's choice cannot
        // show as a line across the band.
        int lo = o.x >= size.x ? size.x : 0, hi = lo + size.x;
        vec4 sum = vec4(0.0); float n = 0.0;
        for (int dy = -4; dy <= 4; ++dy) {
            int ny = clamp(o.y + dy, 0, size.y - 1);
            for (int dx = -2; dx <= 2; ++dx) {
                int nx = o.x + dx;
                if (nx < lo || nx >= hi) continue;
                vec4 nm = texelFetch(map, ivec2(nx, ny), 0);
                if (nm.z < -2.5) { sum += colour(ivec2(nx, ny), nm); n += 1.0; }
            }
        }
        result = sum / n;
        return;
    }
    if (m.w != 0.0) {
        ivec2 q = o + ivec2(int(m.w), 0);
        result = colour(q, texelFetch(map, q, 0));
        return;
    }
    vec4 c = colour(o, m);
    if (m.y >= 0.0) { result = c; return; }
    int lo = o.x >= size.x ? size.x : 0, hi = lo + size.x;
    if (m.z > 2.5) { // the backward map's holes: classify's gate (7x5 spread of placed near) here
        float nmin = 2.0, nmax = -1.0;
        for (int dy = -2; dy <= 2; ++dy) {
            int ny = clamp(o.y + dy, 0, size.y - 1);
            for (int dx = -3; dx <= 3; ++dx) {
                int nx = o.x + dx;
                if (nx < lo || nx >= hi) continue;
                float nz = texelFetch(map, ivec2(nx, ny), 0).y;
                if (nz >= 0.0) { nmin = min(nmin, nz); nmax = max(nmax, nz); }
            }
        }
        m.z = nmax - nmin > 0.30 ? 0.5 * (nmin + nmax) : 2.0;
    }
    vec4 sum = vec4(0.0); float n = 0.0;
    for (int dy = -2; dy <= 2; ++dy) {
        int ny = clamp(o.y + dy, 0, size.y - 1);
        for (int dx = -3; dx <= 3; ++dx) {
            int nx = o.x + dx;
            if (nx < lo || nx >= hi) continue;
            vec4 nm = texelFetch(map, ivec2(nx, ny), 0);
            if (nm.y >= 0.0 && nm.y > m.z) continue;
            sum += colour(ivec2(nx, ny), nm); n += 1.0;
        }
    }
    vec4 blur = n > 0.0 ? sum / n : c;
    result = c * 0.65 + blur * 0.35;
})";
constexpr const char* warp_frame_2d = R"(#version 300 es
precision highp float; precision highp int;
uniform sampler2D source;
)";
constexpr const char* warp_frame_oes = R"(#version 300 es
#extension GL_OES_EGL_image_external_essl3 : require
precision highp float; precision highp int;
uniform samplerExternalOES source;
)";
// Edge stretching ("stretch", the default video 2D->3D view) as a stereo pair: the video shader's
// inverse warp (video_rvm_pair.gdshader depth_parallax), rendered once per video frame so the pair
// can go to the compositor layer instead of being resampled into both eye buffers each display frame.
constexpr const char* stretch_frame_body = R"(
uniform highp sampler2D near_map; // R8 pair mask (linear sampler); the left half is the (limited) near map
uniform vec2 uv_scale;
uniform ivec2 size;     // eye width/height of the pair
uniform ivec2 model;
uniform vec4 content;   // model = content.xy + uv * content.zw
uniform float shift;    // eye-width fraction between nearest and farthest
uniform float convergence;
uniform vec2 footprint; // quarter output pixel in source UV when the pair is scaled down, else zero
uniform bool four_taps;
uniform int photo_rotation; // Still-only virtual clockwise turns (as warp_frame_body); video sets zero.
uniform int text_count;
uniform vec4 text_weights0;
uniform vec4 text_weights1;
uniform vec4 text_regions[8];
out vec4 result;
// One filtered tap over the left half, clamped to the model's own centres (as the shader's filter_linear).
float near_at(vec2 uv) {
    vec2 m = vec2(model);
    vec2 q = clamp(content.xy + uv * content.zw, vec2(0.5) / m, vec2(1.0) - vec2(0.5) / m);
    float n = texture(near_map, vec2(q.x * 0.5, q.y)).r;
    vec2 feather = vec2(2.0) / vec2(size);
    vec2 padding = vec2(abs(shift) * 0.5 * max(convergence, 1.0 - convergence), feather.y);
    float weight = 0.0;
    for (int i = 0; i < 8; ++i) {
        if (i >= text_count) break;
        vec4 r = text_regions[i] + vec4(-padding, padding);
        vec2 d = min(uv - r.xy, r.zw - uv);
        vec2 s = smoothstep(vec2(0.0), feather, d);
        weight = max(weight, s.x * s.y * (i < 4 ? text_weights0[i] : text_weights1[i - 4]));
    }
    return mix(n, convergence, weight);
}
vec3 colour(vec2 p) {
    if (photo_rotation == 1) p = vec2(p.y, 1.0-p.x);
    else if (photo_rotation == 2) p = vec2(1.0)-p;
    else if (photo_rotation == 3) p = vec2(1.0-p.y, p.x);
    if (!four_taps || (footprint.x <= 0.0 && footprint.y <= 0.0)) return texture(source, p * uv_scale).rgb;
    return 0.25 * (texture(source, (p - footprint) * uv_scale).rgb
        + texture(source, (p + vec2(footprint.x, -footprint.y)) * uv_scale).rgb
        + texture(source, (p + vec2(-footprint.x, footprint.y)) * uv_scale).rgb
        + texture(source, (p + footprint) * uv_scale).rgb);
}
void main() {
    ivec2 o = ivec2(gl_FragCoord.xy);
    if (photo_rotation != 0) { // each eye stored in the original orientation, as warp_frame_body
        int original_width = (photo_rotation % 2 == 1) ? size.y : size.x;
        int eye = o.x / original_width;
        ivec2 p = ivec2(o.x - eye * original_width, o.y);
        if (photo_rotation == 1) p = ivec2(size.x-1-p.y, p.x);
        else if (photo_rotation == 2) p = size-ivec2(1)-p;
        else if (photo_rotation == 3) p = ivec2(p.y, size.y-1-p.x);
        o = p + ivec2(eye * size.x, 0);
    }
    int view = o.x >= size.x ? 1 : 0;
    vec2 shown = vec2((float(o.x - view * size.x) + 0.5) / float(size.x), (float(o.y) + 0.5) / float(size.y));
    float side = view == 0 ? 1.0 : -1.0; // left eye: near content moves right, in front of the screen
    float k = shift * 0.5;
    float a = shown.x - side * (1.0 - convergence) * k, b = shown.x + side * convergence * k;
    float lo = min(a, b), hi = max(a, b);
    vec2 p = shown;
    for (int i = 0; i < 6; i++) {
        p.x = 0.5 * (lo + hi);
        if (p.x + side * (near_at(p) - convergence) * k > shown.x) { hi = p.x; } else { lo = p.x; }
    }
    p.x = 0.5 * (lo + hi);
    p.x = shown.x - side * (near_at(p) - convergence) * k;
    vec2 half_texel = vec2(0.5) / vec2(size);
    result = vec4(colour(clamp(p, half_texel, vec2(1.0) - half_texel)), 1.0);
})";
// Steady edges (2D->3D, optional): the near map as a local linear function of the picture's own
// luma, at the map's resolution. This is the guided filter, written here from its publication:
//   Kaiming He, Jian Sun, Xiaoou Tang, "Guided Image Filtering", ECCV 2010;
//   IEEE Transactions on Pattern Analysis and Machine Intelligence 35(6), 2013.
// With guide I (luma) and input p (near), per window k: a_k = cov_k(I, p) / (var_k(I) + epsilon),
// b_k = mean_k(p) - a_k * mean_k(I); the output is q_i = mean(a)_i * I_i + mean(b)_i, every mean a
// box filter. The window, epsilon and working resolution are our own, chosen on our measurements
// (research/video_depth_replay/contour_eval.py). The model's contours wander by
// a texel from frame to frame on a still picture; fitted to the picture over a window they hold,
// and unlike a blur of the same window they keep their step. Pass 0 packs (luma, near, luma^2,
// luma * near); a box across, then a box down that ends in the line's slope and offset; the same
// two boxes over those, the last one evaluating the line with this texel's luma.
constexpr const char* steady_pack_body = R"(
uniform highp sampler2D near_map; // R8 pair mask (linear sampler); the left half is the limited near map
uniform vec2 uv_scale;
uniform ivec2 model;
uniform vec4 content;   // model = content.xy + uv * content.zw
uniform vec2 footprint; // one model texel in picture UV
out vec4 result;
void main() {
    vec2 m = gl_FragCoord.xy / vec2(model);
    vec2 p = clamp((m - content.xy) / content.zw, vec2(0.0), vec2(1.0));
    vec3 sum = vec3(0.0);
    for (int j = 0; j < 4; ++j) for (int i = 0; i < 4; ++i)
        sum += texture(source, clamp(p + (vec2(float(i), float(j)) + 0.5) * footprint * 0.25 - footprint * 0.5, vec2(0.0), vec2(1.0)) * uv_scale).rgb;
    float g = dot(sum / 16.0, vec3(0.2126, 0.7152, 0.0722));
    float d = texture(near_map, vec2(m.x * 0.5, m.y)).r;
    result = vec4(g, d, g * g, g * d);
})";
constexpr const char* steady_box_fragment = R"(#version 300 es
precision highp float; precision highp int;
uniform highp sampler2D source;
uniform highp sampler2D packed;
uniform ivec2 size;   // the model's width and height
uniform ivec2 axis;
uniform int radius;
uniform int stage;    // 0: box; 1: box, then slope and offset; 2: box, then the near value
uniform float epsilon;
out vec4 result;
void main() {
    ivec2 at = ivec2(gl_FragCoord.xy);
    at.x = at.x % size.x; // stage 2 draws both halves of the pair mask
    vec4 sum = vec4(0.0); float n = 0.0;
    for (int i = -12; i <= 12; ++i) {
        if (i < -radius || i > radius) continue;
        ivec2 q = at + axis * i;
        if (q.x < 0 || q.y < 0 || q.x >= size.x || q.y >= size.y) continue;
        sum += texelFetch(source, q, 0); n += 1.0;
    }
    vec4 mean = sum / max(n, 1.0);
    if (stage == 0) { result = mean; return; }
    if (stage == 1) {
        float variance = max(mean.z - mean.x * mean.x, 0.0);
        float slope = (mean.w - mean.x * mean.y) / (variance + epsilon);
        result = vec4(slope, mean.y - slope * mean.x, 0.0, 0.0);
        return;
    }
    result = vec4(clamp(mean.x * texelFetch(packed, at, 0).r + mean.y, 0.0, 1.0));
})";
GLuint shader(GLenum kind, const char* source) {
    const GLuint id = glCreateShader(kind);
    glShaderSource(id, 1, &source, nullptr); glCompileShader(id);
    GLint passed = 0; glGetShaderiv(id, GL_COMPILE_STATUS, &passed);
    if (!passed) {
        char log[1024]{}; glGetShaderInfoLog(id, sizeof(log), nullptr, log); glDeleteShader(id);
        throw std::runtime_error(std::string("Render bridge shader: ") + log);
    }
    return id;
}
GLuint program(const char* fragment) {
    const auto vs = shader(GL_VERTEX_SHADER, vertex);
    GLuint fs = 0;
    try { fs = shader(GL_FRAGMENT_SHADER, fragment); }
    catch (...) { glDeleteShader(vs); throw; }
    const auto id = glCreateProgram(); glAttachShader(id, vs); glAttachShader(id, fs); glLinkProgram(id);
    glDeleteShader(vs); glDeleteShader(fs);
    GLint passed = 0; glGetProgramiv(id, GL_LINK_STATUS, &passed);
    if (!passed) { glDeleteProgram(id); throw std::runtime_error("Render bridge program linking failed"); }
    return id;
}
GLuint compute_program(const char* body) {
    const std::string source = std::string(warp_common) + body;
    const auto cs = shader(GL_COMPUTE_SHADER, source.c_str());
    const auto id = glCreateProgram(); glAttachShader(id, cs); glLinkProgram(id); glDeleteShader(cs);
    GLint passed = 0; glGetProgramiv(id, GL_LINK_STATUS, &passed);
    if (!passed) { glDeleteProgram(id); throw std::runtime_error("Render bridge compute linking failed"); }
    return id;
}
GLuint warp_frame_program(const char* header) { return program((std::string(header) + warp_frame_body).c_str()); }
int mip_levels(int width, int height) {
    int levels = 1;
    for (int size = std::max(width, height); size > 1; size /= 2) ++levels;
    return levels;
}
constexpr const char* portrait_fragment = R"(#version 300 es
precision highp float;
uniform sampler2D source;
uniform sampler2D residual_map;
uniform bool residual_enabled;
uniform float lod_bias;
in vec2 uv;
out vec4 result;
void main() {
    float shape = textureLod(source, uv, max(0.0, 3.0 + lod_bias)).r * 0.5
                + textureLod(source, uv, max(0.0, 4.0 + lod_bias)).r * 0.3
                + textureLod(source, uv, max(0.0, 5.0 + lod_bias)).r * 0.2;
    if (residual_enabled) shape += (texture(residual_map, uv).r - 128.0/255.0) * (255.0/254.0) * 0.7;
    // Reserve headroom above the base body's 1.0: a near hand must rise in front of an
    // already opaque torso instead of saturating at the same depth. R8 decodes by *1.5.
    result = vec4(clamp(shape, 0.0, 1.5)/1.5, 0.0, 0.0, 1.0);
})";
constexpr const char* portrait_mask_fragment = R"(#version 300 es
precision highp float;
uniform sampler2D source;
in vec2 uv;
out vec4 result;
void main() { result = vec4(texture(source,vec2(uv.x*0.5,uv.y)).rrr,1.0); }
)";
struct TextureUnitOne final {
    GLint texture, sampler;
    TextureUnitOne() {
        glActiveTexture(GL_TEXTURE1); glGetIntegerv(GL_TEXTURE_BINDING_2D, &texture);
        glGetIntegerv(GL_SAMPLER_BINDING, &sampler); glBindSampler(1, 0);
    }
    ~TextureUnitOne() {
        glActiveTexture(GL_TEXTURE1); glBindTexture(GL_TEXTURE_2D, texture); glBindSampler(1, sampler);
        glActiveTexture(GL_TEXTURE0);
    }
};
void image(GLuint& id, int width, int height, GLenum format = GL_RGBA8, int levels = 1) {
    glGenTextures(1, &id); glBindTexture(GL_TEXTURE_2D, id);
    glTexStorage2D(GL_TEXTURE_2D, levels, format, width, height);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
}
// Zero-copy: an RGBA8 AHardwareBuffer that GL renders/samples through an EGLImage and
// MNN OpenCL imports directly. CPU usage bits keep the layout linear for that import.
struct SharedImage {
    AHardwareBuffer* buffer = nullptr;
    EGLImageKHR image = EGL_NO_IMAGE_KHR;
    GLuint texture = 0;
};
struct EglImageApi {
    PFNEGLGETNATIVECLIENTBUFFERANDROIDPROC client = nullptr;
    PFNEGLCREATEIMAGEKHRPROC create = nullptr;
    PFNEGLDESTROYIMAGEKHRPROC destroy = nullptr;
    PFNGLEGLIMAGETARGETTEXTURE2DOESPROC target = nullptr;
    EglImageApi() {
        client = reinterpret_cast<PFNEGLGETNATIVECLIENTBUFFERANDROIDPROC>(eglGetProcAddress("eglGetNativeClientBufferANDROID"));
        create = reinterpret_cast<PFNEGLCREATEIMAGEKHRPROC>(eglGetProcAddress("eglCreateImageKHR"));
        destroy = reinterpret_cast<PFNEGLDESTROYIMAGEKHRPROC>(eglGetProcAddress("eglDestroyImageKHR"));
        target = reinterpret_cast<PFNGLEGLIMAGETARGETTEXTURE2DOESPROC>(eglGetProcAddress("glEGLImageTargetTexture2DOES"));
    }
    bool available() const { return client && create && destroy && target; }
};
const EglImageApi& egl_image() { static const EglImageApi api; return api; }
// GPU time of the 2D->3D passes (EXT_disjoint_timer_query), for stats only.
struct TimerApi {
    PFNGLGENQUERIESEXTPROC gen = nullptr;
    PFNGLBEGINQUERYEXTPROC begin = nullptr;
    PFNGLENDQUERYEXTPROC end = nullptr;
    PFNGLGETQUERYOBJECTUIVEXTPROC get = nullptr;
    PFNGLGETQUERYOBJECTUI64VEXTPROC get64 = nullptr;
    TimerApi() {
        const auto* extensions = reinterpret_cast<const char*>(glGetString(GL_EXTENSIONS));
        if (!extensions || !std::strstr(extensions, "GL_EXT_disjoint_timer_query")) return;
        gen = reinterpret_cast<PFNGLGENQUERIESEXTPROC>(eglGetProcAddress("glGenQueriesEXT"));
        begin = reinterpret_cast<PFNGLBEGINQUERYEXTPROC>(eglGetProcAddress("glBeginQueryEXT"));
        end = reinterpret_cast<PFNGLENDQUERYEXTPROC>(eglGetProcAddress("glEndQueryEXT"));
        get = reinterpret_cast<PFNGLGETQUERYOBJECTUIVEXTPROC>(eglGetProcAddress("glGetQueryObjectuivEXT"));
        get64 = reinterpret_cast<PFNGLGETQUERYOBJECTUI64VEXTPROC>(eglGetProcAddress("glGetQueryObjectui64vEXT"));
    }
    bool available() const { return gen && begin && end && get && get64; }
};
const TimerApi& timers() { static const TimerApi api; return api; }
// Godot's GLES renderer does not supply viewport GPU timestamps on Android.
// Reuse the bridge's EXT timer approach, with asynchronous timestamp pairs for
// the whole frame rather than a video pass. No glFinish or blocking result read.
struct FrameTimerApi {
    PFNGLGENQUERIESEXTPROC gen = nullptr;
    PFNGLDELETEQUERIESEXTPROC remove = nullptr;
    PFNGLQUERYCOUNTEREXTPROC counter = nullptr;
    PFNGLGETQUERYOBJECTUIVEXTPROC get = nullptr;
    PFNGLGETQUERYOBJECTUI64VEXTPROC get64 = nullptr;
    void initialize() {
        *this = {};
        const auto* extensions = reinterpret_cast<const char*>(glGetString(GL_EXTENSIONS));
        if (!extensions || !std::strstr(extensions, "GL_EXT_disjoint_timer_query")) return;
        auto query = reinterpret_cast<PFNGLGETQUERYIVEXTPROC>(eglGetProcAddress("glGetQueryivEXT"));
        GLint bits = 0;
        if (query) query(GL_TIMESTAMP_EXT, GL_QUERY_COUNTER_BITS_EXT, &bits);
        if (bits <= 0) return;
        gen = reinterpret_cast<PFNGLGENQUERIESEXTPROC>(eglGetProcAddress("glGenQueriesEXT"));
        remove = reinterpret_cast<PFNGLDELETEQUERIESEXTPROC>(eglGetProcAddress("glDeleteQueriesEXT"));
        counter = reinterpret_cast<PFNGLQUERYCOUNTEREXTPROC>(eglGetProcAddress("glQueryCounterEXT"));
        get = reinterpret_cast<PFNGLGETQUERYOBJECTUIVEXTPROC>(eglGetProcAddress("glGetQueryObjectuivEXT"));
        get64 = reinterpret_cast<PFNGLGETQUERYOBJECTUI64VEXTPROC>(eglGetProcAddress("glGetQueryObjectui64vEXT"));
    }
    bool available() const { return gen && remove && counter && get && get64; }
    bool disjoint() const { GLint value = 0; glGetIntegerv(GL_GPU_DISJOINT_EXT, &value); return value != 0; }
    unsigned create() const { GLuint value = 0; gen(1, &value); return value; }
    void destroy(unsigned value) const { remove(1, &value); }
    void stamp(unsigned value) const { counter(value, GL_TIMESTAMP_EXT); }
    bool ready(unsigned value) const { GLuint ready = 0; get(value, GL_QUERY_RESULT_AVAILABLE_EXT, &ready); return ready != 0; }
    uint64_t result(unsigned value) const { GLuint64 value_ns = 0; get64(value, GL_QUERY_RESULT_EXT, &value_ns); return value_ns; }
};
struct FrameTimer {
    FrameTimerApi api;
    FrameGpuTimingSession<FrameTimerApi> session;
    double update(int action) {
        const auto now = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count();
        return session.update(api, action, reinterpret_cast<uintptr_t>(eglGetCurrentContext()), static_cast<uint64_t>(now));
    }
};
thread_local FrameTimer background_frame_timer;
// One query in flight per measured stage; a stage is skipped while its last result is pending.
struct GpuTimer {
    GLuint query = 0;
    bool pending = false, active = false;
    double ms = 0; uint64_t samples = 0;
    void collect() {
        const auto& api = timers();
        if (!pending) return;
        GLuint ready = 0; api.get(query, GL_QUERY_RESULT_AVAILABLE_EXT, &ready);
        if (!ready) return;
        GLuint64 ns = 0; api.get64(query, GL_QUERY_RESULT_EXT, &ns);
        pending = false;
        GLint disjoint = 0; glGetIntegerv(GL_GPU_DISJOINT_EXT, &disjoint);
        if (disjoint) return;
        ms = samples ? ms * 0.9 + ns / 1e6 * 0.1 : ns / 1e6; samples++;
    }
    void start() {
        const auto& api = timers();
        if (!api.available()) return;
        collect();
        if (pending) return;
        if (!query) api.gen(1, &query);
        api.begin(GL_TIME_ELAPSED_EXT, query); active = true;
    }
    void stop() { if (active) { timers().end(GL_TIME_ELAPSED_EXT); active = false; pending = true; } }
};
SharedImage make_shared_image(int width, int height, uint64_t usage) {
    check_gl("Before zero-copy image allocation");
    // Scout outputs can be allocated by zeroCopyBuffers(), outside a capture's
    // State guard. Never leave a private texture bound in Godot's active unit.
    State state;
    const auto& api = egl_image();
    if (!api.available()) throw std::runtime_error("EGLImage/AHardwareBuffer interop unavailable");
    SharedImage result;
    AHardwareBuffer_Desc desc{};
    desc.width = static_cast<uint32_t>(width); desc.height = static_cast<uint32_t>(height); desc.layers = 1;
    desc.format = AHARDWAREBUFFER_FORMAT_R8G8B8A8_UNORM; desc.usage = usage;
    if (AHardwareBuffer_allocate(&desc, &result.buffer) != 0 || !result.buffer)
        throw std::runtime_error("Zero-copy AHardwareBuffer allocation failed");
    const EGLint attributes[] = {EGL_IMAGE_PRESERVED_KHR, EGL_TRUE, EGL_NONE};
    result.image = api.create(eglGetCurrentDisplay(), EGL_NO_CONTEXT, EGL_NATIVE_BUFFER_ANDROID,
                              api.client(result.buffer), attributes);
    if (result.image == EGL_NO_IMAGE_KHR) { AHardwareBuffer_release(result.buffer); throw std::runtime_error("Zero-copy EGLImage creation failed"); }
    try {
        glGenTextures(1, &result.texture); glBindTexture(GL_TEXTURE_2D, result.texture);
        check_gl("Zero-copy texture name binding");
        api.target(GL_TEXTURE_2D, static_cast<GLeglImageOES>(result.image));
        check_gl("Zero-copy EGLImage binding");
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        check_gl("Zero-copy texture parameters");
    } catch (...) {
        if (result.texture) glDeleteTextures(1, &result.texture);
        api.destroy(eglGetCurrentDisplay(), result.image);
        AHardwareBuffer_release(result.buffer);
        throw;
    }
    return result;
}
void destroy_shared_image(SharedImage& image) {
    if (image.texture) glDeleteTextures(1, &image.texture);
    if (image.image != EGL_NO_IMAGE_KHR) egl_image().destroy(eglGetCurrentDisplay(), image.image);
    if (image.buffer) AHardwareBuffer_release(image.buffer);
    image = {};
}
constexpr uint64_t kInputUsage = AHARDWAREBUFFER_USAGE_GPU_FRAMEBUFFER | AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE |
                                 AHARDWAREBUFFER_USAGE_CPU_READ_RARELY;
constexpr uint64_t kOutputUsage = AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE | AHARDWAREBUFFER_USAGE_CPU_READ_RARELY |
                                  AHARDWAREBUFFER_USAGE_CPU_WRITE_RARELY;
enum class Phase { free, copying, held, retiring };
struct Slot {
    GLuint color = 0, alpha = 0;
    GLuint shot_pbo = 0;
    GLuint portrait_mask_pbo = 0;
    bool portrait_mask_staged = false;
    GLuint portrait = 0, portrait_mips = 0; // Shape and private mip source, leased with this exact color/Alpha.
    bool portrait_valid = false;
    // Borrowed color: the producer's own immutable texture, kept leased by the owner until this
    // slot retires, instead of a full-resolution copy into `color` (allocated only when copying).
    GLuint borrowed = 0;
    GLuint source() const { return borrowed ? borrowed : color; }
    // Decoder image (MPV direct mode): an external OES texture over the MediaCodec buffer the
    // owner keeps leased; Godot samples the same EGLImage. Released when the slot is free.
    EGLImageKHR decoder_image = EGL_NO_IMAGE_KHR;
    GLuint decoder_texture = 0;
    std::array<float, 2> uv_scale{{1.f, 1.f}};
    std::array<GLuint, 2> pbo{{0, 0}};
    std::array<GLuint, 2> scout_pbo{{0, 0}}; // ROI: full-eye input staged from the same color
    bool scout_staged = false;
    std::array<SharedImage, 2> zc_in, zc_out, zc_scout_in; // zero-copy, allocated on first use
    GLsync fence = nullptr, alpha_fence = nullptr;
    bool alpha_valid = false;
    std::vector<unsigned char> near; // last uploaded mask bytes (2D->3D: the near map)
    std::vector<float> text_regions, text_weights; // immutable source UV protection for this colour token
    GLuint warp = 0;                 // 2D->3D stereo pair (2W x H) of this color
    bool opaque_cached = false, opaque_pending = false;
    Phase phase = Phase::free;
    jlong token = 0;
};
struct Bridge final {
    const EGLContext context = eglGetCurrentContext();
    const std::thread::id thread = std::this_thread::get_id();
    const int width, height, input_width, input_height;
    // 0 mono, 1 side by side (left half first), 2 top-bottom (top half first; canonical row 0 is top).
    const int layout;
    bool abandoned = false;
    GLuint oes = 0, copy = 0, copy_2d = 0, scale = 0, scale_oes = 0, freeze_oes = 0, vao = 0, fbo = 0, small = 0;
    // Display, retiring, inference, pending and staging can overlap; with borrowed colors a slot is
    // only the model inputs and the R8 mask, so five cost little. 2D->3D keeps each slot until its
    // stereo pair is rendered: two more slots keep 60 fps sources from running out.
    std::array<Slot, 7> slots;
    // Memory saver: captures use only the first slot_limit slots (each holds a full-size color).
    size_t slot_limit = 7;
    Slot* free_slot() {
        for (size_t i = 0; i < std::min(slot_limit, slots.size()); ++i) if (slots[i].phase == Phase::free) return &slots[i];
        return nullptr;
    }
    uint64_t copies = 0, opaque_copies = 0, opaque_uploads = 0, alpha_uploads = 0;
    uint64_t input_stages = 0, copy_pending_polls = 0, retire_pending_polls = 0, slot_exhaustions = 0;
    std::array<float, 4> content_rect{{0, 0, 1, 1}};
    bool zero_copy = false;
    bool edge_fill = false; // 2D->3D: letterbox in the model input repeats the content edge
    bool borrow = false; // capture_texture keeps the producer texture instead of copying it
    uint64_t borrows = 0, decoder_captures = 0;
    std::array<SharedImage, 2> zc_scout_out; // one scout runs at a time; read on the CPU right after
    uint64_t zero_copy_commits = 0;
    // 2D->3D stereo (mono sources only): see warp_common.
    GLuint warp_keys = 0, warp_map = 0, warp_kept = 0;
    GLuint snap_texture = 0; // stills: the unlimited near map winners are snapped from (warp_common split)
    std::string photo_passes; // a still's last render_warp, per pass in ms
    GLuint warp_clear_prog = 0, warp_scatter_prog = 0, warp_keep_prog = 0, warp_classify_prog = 0, warp_frame_2d_prog = 0, warp_frame_oes_prog = 0;
    bool warp_failed = false;
    // Video pair eye size: the fill warp keeps the source size, edge stretching may scale it.
    int warp_width = 0, warp_height = 0;
    // Native edge stretching: on for Adreno 7xx and newer (Quest 3 4K60: 56.5-57.7 video fps against 58.5-58.7
    // in the eye buffers); XR2 Gen 1 class GPUs keep the shader. `setprop debug.vrpp.stretch.native 0|1` overrides.
    GLuint stretch_2d_prog = 0, stretch_oes_prog = 0, stretch_sampler = 0;
    int stretch_native = -1, stretch_taps = 4; // debug.vrpp.stretch.taps 1: one colour tap when scaled
    uint64_t stretch_frames = 0;
    // Steady edges (see steady_pack_body): set per upload with the near limit; off leaves the map as limited.
    bool steady = false, steady_failed = false;
    int steady_radius = 3; float steady_epsilon = 2.5e-4f;
    GLuint steady_pack_2d = 0, steady_pack_oes = 0, steady_box = 0, steady_sampler = 0;
    GLuint steady_packed = 0, steady_scratch = 0, steady_line = 0;
    uint64_t steady_maps = 0;
    std::vector<unsigned char> map_near; // near map the current `warp_map` was built from
    float map_half = -1.f, map_convergence = -1.f;
    std::vector<float> map_text, map_text_weights;
    uint64_t warp_frames = 0, warp_maps = 0;
    // `setprop debug.vrpp.warp.time 1`: video warps glFinish around the map and the frame pass and log
    // their wall time every 48 frames (the GPU timers miss compute on Adreno). Read once per bridge.
    // Fill gaps from the backward map (fill_map_fragment), unless debug.vrpp.fill.v2 0 asks for the compute passes.
    // Video only: stills keep the compute warp, whose bridging and rim cleanup the backward map lacks
    // (on Quest 3 stills at 200% it left more slivers; research/video_depth_replay/photo_fill_sheet.py).
    int fill_4k = -1;
    // Holes stretched by position (fill_run_fragment, fill_rows_fragment) with a continuous near/far threshold
    // (window_map): the default for stills and video; debug.vrpp.fill.position 0 restores plain holes.
    int fill_position = -1;
    GLuint fill_run_prog = 0, fill_rows_prog = 0, warp_map2 = 0;
    int fill_v2 = -1; GLuint fill_window_prog = 0, fill_map_prog = 0, fill_window = 0;
    int warp_time = -1; double warp_time_map = 0, warp_time_frame = 0; int warp_time_maps = 0, warp_time_frames = 0;
    // Video 2D->3D: the near texture's falls are limited for the parallax being shown, as
    // photo_limit_gradient. Steeper falls make the video shader's fixed-point lookup (edge stretch)
    // fold back, and the warp's hole fill reach across the silhouette (fill); both repeat the
    // subject's contour beside it. slot.near keeps the model's map.
    float near_limit_shift = 0.f;
    std::vector<unsigned char> limited_near(const std::vector<unsigned char>& packed) const {
        const float half = near_limit_shift * 0.5f * content_rect[2] * input_width;
        if (half <= 0.f) return packed;
        const int w = input_width, h = input_height;
        std::vector<float> plane(static_cast<size_t>(w) * h);
        for (int y = 0; y < h; ++y) for (int x = 0; x < w; ++x)
            plane[static_cast<size_t>(y)*w+x] = packed[static_cast<size_t>(y)*w*2+x] / 255.f;
        const int cx = std::clamp(static_cast<int>(std::lround(content_rect[0] * w)), 0, w - 1);
        const int cy = std::clamp(static_cast<int>(std::lround(content_rect[1] * h)), 0, h - 1);
        const int cw = std::clamp(static_cast<int>(std::lround(content_rect[2] * w)), 1, w - cx);
        const int ch = std::clamp(static_cast<int>(std::lround(content_rect[3] * h)), 1, h - cy);
        quest::photo_limit_gradient(plane.data(), w, h, cx, cy, cw, ch, half);
        std::vector<unsigned char> result(packed);
        for (int y = 0; y < h; ++y) for (int x = 0; x < w; ++x) {
            const auto value = static_cast<unsigned char>(std::lround(std::clamp(plane[static_cast<size_t>(y)*w+x], 0.f, 1.f) * 255.f));
            result[static_cast<size_t>(y)*w*2+x] = value; result[static_cast<size_t>(y)*w*2+w+x] = value;
        }
        return result;
    }
    GpuTimer map_timer, frame_timer, portrait_timer;
    uint64_t portrait_frames = 0;
    GLuint portrait_program = 0;
    GLuint shot_image = 0;
    GLuint portrait_mask_program = 0, portrait_mask_image = 0, portrait_input_image = 0, portrait_residual_image = 0;
    int portrait_input_width = 0, portrait_input_height = 0;
    GLuint portrait_input_pbo = 0;
    GLsync portrait_input_fence = nullptr;
    Bridge(int w, int h, int iw, int ih, int l) : width(w), height(h), input_width(iw), input_height(ih), layout(l) {}
    float eye_width() const { return width / (layout == 1 ? 2.f : 1.f); }
    float eye_height() const { return height / (layout == 2 ? 2.f : 1.f); }
    void eye_rect(GLuint prog, int eye) const {
        if (layout == 1) glUniform4f(glGetUniformLocation(prog, "eye_rect"), eye * 0.5f, 0.f, 0.5f, 1.f);
        else if (layout == 2) glUniform4f(glGetUniformLocation(prog, "eye_rect"), 0.f, eye * 0.5f, 1.f, 0.5f);
        else glUniform4f(glGetUniformLocation(prog, "eye_rect"), 0.f, 0.f, 1.f, 1.f);
    }
    void current() const {
        if (context == EGL_NO_CONTEXT || context != eglGetCurrentContext() || thread != std::this_thread::get_id())
            throw std::runtime_error("Render bridge requires its owner GL thread/context");
    }
    void allocate() {
        current(); drain_gl("bridge allocation"); State state;
        GLint maximum = 0; glGetIntegerv(GL_MAX_TEXTURE_SIZE, &maximum);
        if (width > maximum || height > maximum) throw std::runtime_error("Source exceeds GL texture limit");
        copy = program(copy_fragment); copy_2d = program(copy_2d_fragment); scale = program(scale_fragment);
        glGenVertexArrays(1, &vao); glGenFramebuffers(1, &fbo); glGenTextures(1, &oes);
        glBindTexture(GL_TEXTURE_EXTERNAL_OES, oes);
        glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        check_gl("Render bridge programs");
        image(small, input_width, input_height);
        check_gl("Render bridge input image");
        const GLsizeiptr bytes = static_cast<GLsizeiptr>(input_width) * input_height * 4;
        for (auto& slot : slots) {
            glGenBuffers(2, slot.pbo.data());
            for (auto pbo : slot.pbo) { glBindBuffer(GL_PIXEL_PACK_BUFFER, pbo); glBufferData(GL_PIXEL_PACK_BUFFER, bytes, nullptr, GL_STREAM_READ); }
        }
        const float source_aspect = eye_width() / eye_height();
        const float input_aspect = static_cast<float>(input_width) / input_height;
        if (source_aspect > input_aspect) { content_rect[3] = input_aspect / source_aspect; content_rect[1] = (1.f-content_rect[3])*0.5f; }
        else { content_rect[2] = source_aspect / input_aspect; content_rect[0] = (1.f-content_rect[2])*0.5f; }
        check_gl("Render bridge allocation");
    }
    ~Bridge() {
        if (abandoned || context != eglGetCurrentContext() || thread != std::this_thread::get_id()) return; // Dead context: names must never be deleted in a new one.
        for (auto& slot : slots) {
            if (slot.fence) glDeleteSync(slot.fence);
            if (slot.alpha_fence) glDeleteSync(slot.alpha_fence);
            glDeleteBuffers(2, slot.pbo.data()); glDeleteTextures(1, &slot.color); glDeleteTextures(1, &slot.alpha);
            glDeleteTextures(1, &slot.portrait);
            glDeleteTextures(1, &slot.portrait_mips);
            glDeleteBuffers(1, &slot.shot_pbo);
            glDeleteBuffers(1, &slot.portrait_mask_pbo);
            if (slot.warp) glDeleteTextures(1, &slot.warp);
            if (slot.scout_pbo[0]) glDeleteBuffers(2, slot.scout_pbo.data());
            for (auto* set : {&slot.zc_in, &slot.zc_out, &slot.zc_scout_in}) for (auto& image : *set) destroy_shared_image(image);
            release_decoder(slot);
        }
        for (auto& image : zc_scout_out) destroy_shared_image(image);
        glDeleteTextures(1, &small); glDeleteTextures(1, &oes); glDeleteFramebuffers(1, &fbo); glDeleteVertexArrays(1, &vao);
        if (copy) glDeleteProgram(copy);
        if (copy_2d) glDeleteProgram(copy_2d);
        if (portrait_program) glDeleteProgram(portrait_program);
        glDeleteTextures(1, &shot_image);
        if (portrait_mask_program) glDeleteProgram(portrait_mask_program);
        glDeleteTextures(1, &portrait_mask_image); glDeleteTextures(1, &portrait_input_image);
        glDeleteTextures(1, &portrait_residual_image);
        glDeleteBuffers(1, &portrait_input_pbo);
        if (portrait_input_fence) glDeleteSync(portrait_input_fence);
        if (scale) glDeleteProgram(scale);
        if (scale_oes) glDeleteProgram(scale_oes);
        if (freeze_oes) glDeleteProgram(freeze_oes);
        if (warp_keys) glDeleteBuffers(1, &warp_keys);
        if (warp_kept) glDeleteBuffers(1, &warp_kept);
        if (warp_map) glDeleteTextures(1, &warp_map);
        if (snap_texture) glDeleteTextures(1, &snap_texture);
        if (stretch_sampler) glDeleteSamplers(1, &stretch_sampler);
        if (steady_sampler) glDeleteSamplers(1, &steady_sampler);
        for (GLuint texture : {steady_packed, steady_scratch, steady_line}) if (texture) glDeleteTextures(1, &texture);
        for (GLuint prog : {steady_pack_2d, steady_pack_oes, steady_box}) if (prog) glDeleteProgram(prog);
        for (GLuint prog : {fill_window_prog, fill_map_prog, fill_run_prog, fill_rows_prog}) if (prog) glDeleteProgram(prog);
        if (fill_window) glDeleteTextures(1, &fill_window);
        if (warp_map2) glDeleteTextures(1, &warp_map2);
        for (GLuint prog : {warp_clear_prog, warp_scatter_prog, warp_keep_prog, warp_classify_prog, warp_frame_2d_prog, warp_frame_oes_prog,
                            stretch_2d_prog, stretch_oes_prog})
            if (prog) glDeleteProgram(prog);
    }
    static void release_decoder(Slot& slot) {
        if (slot.decoder_texture) glDeleteTextures(1, &slot.decoder_texture);
        if (slot.decoder_image != EGL_NO_IMAGE_KHR) egl_image().destroy(eglGetCurrentDisplay(), slot.decoder_image);
        slot.decoder_texture = 0; slot.decoder_image = EGL_NO_IMAGE_KHR; slot.uv_scale = {{1.f, 1.f}};
    }
    void target(GLuint texture, int w, int h) {
        glBindFramebuffer(GL_FRAMEBUFFER, fbo); glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0);
        if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) throw std::runtime_error("Render bridge framebuffer incomplete");
        glViewport(0, 0, w, h); glBindVertexArray(vao);
    }
    bool poll(Slot& slot) {
        if (!slot.fence) return slot.phase == Phase::held;
        const auto result = glClientWaitSync(slot.fence, 0, 0);
        if (result == GL_WAIT_FAILED) throw std::runtime_error("Render bridge fence failed");
        if (result != GL_ALREADY_SIGNALED && result != GL_CONDITION_SATISFIED) {
            if (slot.phase == Phase::copying) copy_pending_polls++;
            else if (slot.phase == Phase::retiring) retire_pending_polls++;
            return false;
        }
        glDeleteSync(slot.fence); slot.fence = nullptr;
        slot.phase = slot.phase == Phase::copying ? Phase::held : Phase::free;
        if (slot.phase == Phase::free) release_decoder(slot);
        if (slot.phase == Phase::held && slot.opaque_pending) slot.alpha_valid = true;
        return slot.phase == Phase::held;
    }
    Slot& find(jlong token) {
        for (auto& slot : slots) if (token > 0 && slot.token == token && slot.phase != Phase::free) return slot;
        throw std::runtime_error("Render bridge lease stale/unknown");
    }
    jlong capture(const GLfloat* transform, jlong token) {
        current(); drain_gl("bridge capture"); State state;
        Slot* free = nullptr;
        // retired() is the owner's acknowledgement of the release fence. A
        // signalled fence alone must not let capture overwrite its old token
        // while the caller still keeps that token in its retirement set.
        free = free_slot();
        if (!free) return 0;
        free->alpha_valid = false; free->portrait_valid = false;
        free->opaque_pending = false;
        free->borrowed = 0;
        if (!free->color) image(free->color, width, height);
        target(free->color, width, height); glUseProgram(copy); glBindTexture(GL_TEXTURE_EXTERNAL_OES, oes);
        glUniform1i(glGetUniformLocation(copy, "source"), 0); glUniformMatrix4fv(glGetUniformLocation(copy, "transform"), 1, GL_FALSE, transform);
        glDrawArrays(GL_TRIANGLES, 0, 3);
        return stage(*free, token);
    }
    // Normal playback: a constant full mask, uploaded once per slot and valid with the color fence.
    void opaque_mask(Slot& slot) {
        slot.opaque_pending = true;
        if (!slot.opaque_cached) {
            if (!slot.alpha) image(slot.alpha, input_width*2, input_height, GL_R8);
            std::vector<unsigned char> mask(static_cast<size_t>(input_width)*input_height*2, 255);
            glBindTexture(GL_TEXTURE_2D, slot.alpha);
            glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, input_width*2, input_height, GL_RED, GL_UNSIGNED_BYTE, mask.data());
            check_gl("Render bridge opaque mask upload");
            slot.opaque_cached = true; opaque_uploads++;
        }
        opaque_copies++;
    }
    jlong capture_texture(GLuint source, jlong token, bool inputs, bool opaque = false,
                          const float* window = nullptr, bool scout = false) {
        current(); drain_gl("bridge texture capture"); State state;
        if (!source || !glIsTexture(source)) throw std::runtime_error("Shared MPV color texture unavailable");
        Slot* free = nullptr;
        free = free_slot();
        if (!free) { slot_exhaustions++; return 0; }
        free->alpha_valid = false; free->portrait_valid = false;
        free->opaque_pending = opaque;
        if (borrow) {
            // The owner keeps the producer lease until this slot retires; staging samples it directly.
            free->borrowed = source; borrows++;
        } else {
            free->borrowed = 0;
            if (!free->color) { image(free->color, width, height); check_gl("Render bridge color allocation"); }
            target(free->color, width, height); glUseProgram(copy_2d);
            glBindTexture(GL_TEXTURE_2D, source); glUniform1i(glGetUniformLocation(copy_2d, "source"), 0);
            // The producer lease lasts until a consumer-context fence after this copy.
            // MPV FLIP_Y=0 already stores source top rows at GL y=0.
            glDrawArrays(GL_TRIANGLES, 0, 3);
            copies++;
        }
        if (opaque) {
            if (inputs) throw std::runtime_error("Opaque capture cannot stage inference inputs");
            opaque_mask(*free);
        }
        free->scout_staged = false;
        if (scout) {
            if (!inputs || opaque) throw std::runtime_error("ROI scout requires staged inference inputs");
            if (!free->scout_pbo[0]) {
                glGenBuffers(2, free->scout_pbo.data());
                const GLsizeiptr bytes = static_cast<GLsizeiptr>(input_width) * input_height * 4;
                for (auto pbo : free->scout_pbo) { glBindBuffer(GL_PIXEL_PACK_BUFFER, pbo); glBufferData(GL_PIXEL_PACK_BUFFER, bytes, nullptr, GL_STREAM_READ); }
            }
            if (zero_copy) stage_shared(*free, content_rect.data(), free->zc_scout_in);
            else stage_inputs(*free, content_rect.data(), free->scout_pbo);
            free->scout_staged = true;
        }
        return stage(*free, token, inputs, window ? window : content_rect.data());
    }
    // MPV direct mode: the pair shows the decoder's buffer (the owner keeps its MPV lease until this
    // slot retires); the model input is scaled straight from it, YUV sampled as RGB by the GPU.
    // Opaque (normal playback): no model input, the slot carries the constant full mask instead.
    jlong capture_buffer(AHardwareBuffer* buffer, int buffer_width, int buffer_height, jlong token,
                         const float* window, bool scout, bool opaque = false) {
        current(); drain_gl("bridge decoder capture"); State state;
        if (!buffer || buffer_width < width || buffer_height < height) throw std::runtime_error("Decoder buffer invalid");
        const auto& api = egl_image();
        if (!api.available()) throw std::runtime_error("EGLImage/AHardwareBuffer interop unavailable");
        if (!scale_oes) scale_oes = program(scale_oes_fragment);
        Slot* free = nullptr;
        free = free_slot();
        if (!free) { slot_exhaustions++; return 0; }
        release_decoder(*free);
        free->alpha_valid = false; free->portrait_valid = false; free->opaque_pending = false; free->borrowed = 0;
        const EGLint attributes[] = {EGL_IMAGE_PRESERVED_KHR, EGL_TRUE, EGL_NONE};
        free->decoder_image = api.create(eglGetCurrentDisplay(), EGL_NO_CONTEXT, EGL_NATIVE_BUFFER_ANDROID, api.client(buffer), attributes);
        if (free->decoder_image == EGL_NO_IMAGE_KHR) throw std::runtime_error("Decoder EGLImage creation failed");
        glGenTextures(1, &free->decoder_texture); glBindTexture(GL_TEXTURE_EXTERNAL_OES, free->decoder_texture);
        api.target(GL_TEXTURE_EXTERNAL_OES, static_cast<GLeglImageOES>(free->decoder_image));
        check_gl("Decoder EGLImage binding");
        glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MIN_FILTER, GL_LINEAR); glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE); glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        free->uv_scale = {{static_cast<float>(width) / buffer_width, static_cast<float>(height) / buffer_height}};
        decoder_captures++;
        free->scout_staged = false;
        if (opaque) {
            if (scout) throw std::runtime_error("ROI scout requires staged inference inputs");
            opaque_mask(*free);
            return stage(*free, token, false);
        }
        if (scout) {
            if (!free->scout_pbo[0]) {
                glGenBuffers(2, free->scout_pbo.data());
                const GLsizeiptr bytes = static_cast<GLsizeiptr>(input_width) * input_height * 4;
                for (auto pbo : free->scout_pbo) { glBindBuffer(GL_PIXEL_PACK_BUFFER, pbo); glBufferData(GL_PIXEL_PACK_BUFFER, bytes, nullptr, GL_STREAM_READ); }
            }
            if (zero_copy) stage_shared(*free, content_rect.data(), free->zc_scout_in);
            else stage_inputs(*free, content_rect.data(), free->scout_pbo);
            free->scout_staged = true;
        }
        return stage(*free, token, true, window ? window : content_rect.data());
    }
    // rect maps eye UV into model UV: model = rect.xy + eye * rect.zw. The full-eye
    // letterbox has rect inside [0,1]; an ROI zoom window has rect.zw > 1.
    // Binds the slot's source image and returns the scale program with its common uniforms set.
    GLuint bind_scale(Slot& slot, const float* rect) {
        const GLuint prog = slot.decoder_texture ? scale_oes : scale;
        glUseProgram(prog);
        if (slot.decoder_texture) {
            glBindTexture(GL_TEXTURE_EXTERNAL_OES, slot.decoder_texture);
            glUniform2f(glGetUniformLocation(prog, "uv_scale"), slot.uv_scale[0], slot.uv_scale[1]);
        } else glBindTexture(GL_TEXTURE_2D, slot.source());
        glUniform1i(glGetUniformLocation(prog, "source"), 0); glUniform4fv(glGetUniformLocation(prog, "content_rect"), 1, rect);
        glUniform2f(glGetUniformLocation(prog, "eye_size"), eye_width(), eye_height());
        glUniform2f(glGetUniformLocation(prog, "footprint"), 1.f / input_width / rect[2], 1.f / input_height / rect[3]);
        glUniform1i(glGetUniformLocation(prog, "edge_fill"), edge_fill ? 1 : 0);
        return prog;
    }
    void stage_inputs(Slot& slot, const float* rect, const std::array<GLuint, 2>& pbos) {
        input_stages++;
        target(small, input_width, input_height);
        const GLuint prog = bind_scale(slot, rect);
        // Mono eyes have identical model input. One draw/readback also serves RVM's
        // second host plane; stereo keeps two independent captures.
        for (int eye = 0; eye < (layout == 0 ? 1 : 2); ++eye) {
            eye_rect(prog, eye);
            glDrawArrays(GL_TRIANGLES, 0, 3); glBindBuffer(GL_PIXEL_PACK_BUFFER, pbos[eye]);
            // Only the model-size render target is ever read back. RGBA rows are 4-byte aligned.
            glReadPixels(0, 0, input_width, input_height, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
        }
    }
    // Tiny full-source colour fingerprint, staged before the existing copy fence is consumed.
    // Keep this independent of the inference crop and of zero-copy vs host-copy transport.
    void stage_shot(jlong token) {
        current(); auto& slot = find(token);
        if (layout != 0 || slot.phase != Phase::copying || !slot.fence)
            throw std::runtime_error("Shot staging requires a copying mono frame");
        State state;
        if (!shot_image) image(shot_image, 48, 32);
        if (!slot.shot_pbo) {
            glGenBuffers(1, &slot.shot_pbo); glBindBuffer(GL_PIXEL_PACK_BUFFER, slot.shot_pbo);
            glBufferData(GL_PIXEL_PACK_BUFFER, 48*32*4, nullptr, GL_STREAM_READ);
        }
        target(shot_image, 48, 32);
        const float rect[] = {0.f, 0.f, 1.f, 1.f};
        const GLuint prog = bind_scale(slot, rect); eye_rect(prog, 0);
        glUniform2f(glGetUniformLocation(prog, "footprint"), 1.f/48, 1.f/32);
        glDrawArrays(GL_TRIANGLES, 0, 3); glBindBuffer(GL_PIXEL_PACK_BUFFER, slot.shot_pbo);
        glReadPixels(0, 0, 48, 32, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
        check_gl("Portrait shot staging");
        glDeleteSync(slot.fence); slot.fence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
        if (!slot.fence) throw std::runtime_error("Shot staging fence unavailable");
        glFlush();
    }
    void read_shot(jlong token, unsigned char* bytes) {
        current(); auto& slot = find(token);
        if (slot.phase != Phase::held || !slot.shot_pbo) throw std::runtime_error("Shot read requires completed staging");
        State state; glBindBuffer(GL_PIXEL_PACK_BUFFER, slot.shot_pbo);
        const auto* mapped = glMapBufferRange(GL_PIXEL_PACK_BUFFER, 0, 48*32*4, GL_MAP_READ_BIT);
        if (!mapped) throw std::runtime_error("Shot PBO mapping failed");
        std::memcpy(bytes, mapped, 48*32*4);
        if (!glUnmapBuffer(GL_PIXEL_PACK_BUFFER)) throw std::runtime_error("Shot PBO corrupted");
    }
    void ensure_shared(std::array<SharedImage, 2>& images, uint64_t usage) {
        for (auto& image : images) if (!image.buffer) image = make_shared_image(input_width, input_height, usage);
    }
    // Zero-copy staging: render each eye's model input straight into its AHardwareBuffer.
    void stage_shared(Slot& slot, const float* rect, std::array<SharedImage, 2>& targets) {
        ensure_shared(targets, kInputUsage);
        input_stages++;
        for (int eye = 0; eye < 2; ++eye) {
            target(targets[eye].texture, input_width, input_height);
            const GLuint prog = bind_scale(slot, rect);
            eye_rect(prog, eye);
            glDrawArrays(GL_TRIANGLES, 0, 3);
        }
    }
    // Zero-copy Alpha: MNN wrote round(alpha*255) into R of each eye's buffer; pack both eyes
    // into the slot's R8 mask on the GPU, fenced exactly like a CPU upload.
    void commit_zero_copy_alpha(jlong token) {
        current(); auto& slot = find(token);
        if (!zero_copy || !slot.zc_out[0].buffer || slot.phase != Phase::held || slot.alpha_fence || slot.alpha_valid)
            throw std::runtime_error("Zero-copy Alpha commit requires a held color with no existing mask");
        State state;
        slot.portrait_valid = false;
        if (!slot.alpha) image(slot.alpha, input_width*2, input_height, GL_R8);
        glBindFramebuffer(GL_FRAMEBUFFER, fbo); glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, slot.alpha, 0);
        if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) throw std::runtime_error("Zero-copy mask framebuffer incomplete");
        glBindVertexArray(vao); glUseProgram(copy_2d); glUniform1i(glGetUniformLocation(copy_2d, "source"), 0);
        for (int eye = 0; eye < 2; ++eye) {
            glViewport(eye * input_width, 0, input_width, input_height);
            glBindTexture(GL_TEXTURE_2D, slot.zc_out[layout == 0 ? 0 : eye].texture);
            glDrawArrays(GL_TRIANGLES, 0, 3);
        }
        slot.opaque_cached = false;
        if (glGetError() != GL_NO_ERROR) throw std::runtime_error("Zero-copy Alpha commit GL error");
        slot.alpha_fence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
        if (!slot.alpha_fence) throw std::runtime_error("Zero-copy Alpha fence unavailable");
        zero_copy_commits++; alpha_uploads++;
        glFlush();
    }
    jlong stage(Slot& slot, jlong token, bool inputs = true, const float* rect = nullptr) {
        if (inputs && zero_copy) { ensure_shared(slot.zc_out, kOutputUsage); stage_shared(slot, rect ? rect : content_rect.data(), slot.zc_in); }
        else if (inputs) stage_inputs(slot, rect ? rect : content_rect.data(), slot.pbo);
        check_gl("Render bridge copy/staging");
        slot.fence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
        if (!slot.fence) throw std::runtime_error("Render bridge copy fence unavailable");
        slot.text_regions.clear();slot.text_weights.clear(); slot.token = token; slot.phase = Phase::copying; glFlush();
        return token;
    }
    void upload_alpha(jlong token, const float* left, const float* right) {
        current(); auto& slot = find(token);
        if (slot.phase != Phase::held || slot.alpha_fence || slot.alpha_valid)
            throw std::runtime_error("Alpha upload requires an immutable color with no existing mask");
        const size_t plane = static_cast<size_t>(input_width) * input_height;
        const auto a = reinterpret_cast<uintptr_t>(left), b = reinterpret_cast<uintptr_t>(right);
        const size_t bytes = plane * sizeof(float);
        if ((a <= b && b-a < bytes) || (b < a && a-b < bytes)) throw std::runtime_error("Alpha inputs overlap");
        std::vector<unsigned char> packed(plane * 2);
        for (int eye = 0; eye < 2; ++eye) {
            const auto* input = eye == 0 ? left : right;
            for (int y = 0; y < input_height; ++y) for (int x = 0; x < input_width; ++x) {
                const float value = input[static_cast<size_t>(y)*input_width+x];
                if (!std::isfinite(value) || value < 0.f || value > 1.f)
                    throw std::runtime_error("Alpha must contain finite numeric values in [0,1]");
                packed[static_cast<size_t>(y)*input_width*2+eye*input_width+x] = static_cast<unsigned char>(std::lround(value*255.f));
            }
        }
        // Validate both eyes before modifying the slot. Rows are canonical top-left.
        State state;
        slot.portrait_valid = false;
        if (!slot.alpha) image(slot.alpha, input_width*2, input_height, GL_R8);
        glBindTexture(GL_TEXTURE_2D, slot.alpha);
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, input_width*2, input_height, GL_RED, GL_UNSIGNED_BYTE, limited_near(packed).data());
        slot.near = std::move(packed);
        slot.opaque_cached = false;
        if (glGetError() != GL_NO_ERROR) throw std::runtime_error("Alpha upload GL error");
        steady_near(slot);
        slot.alpha_fence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
        if (!slot.alpha_fence) throw std::runtime_error("Alpha upload fence unavailable");
        alpha_uploads++;
        glFlush();
    }
    // Rewrites the just uploaded (limited) near map of a 2D->3D slot or a still with its steady-edge version.
    // The caller holds the GL state and renews the slot's fence. Any GL refusal turns the feature off
    // for this bridge and leaves the map as uploaded.
    void steady_near(Slot& slot) {
        if (!steady || steady_failed || layout != 0 || !slot.alpha) return;
        if (!slot.decoder_texture && !slot.source()) return;
        const int w = input_width, h = input_height;
        GLint unit1_2d = 0, unit1_sampler = 0;
        glActiveTexture(GL_TEXTURE1); glGetIntegerv(GL_TEXTURE_BINDING_2D, &unit1_2d); glGetIntegerv(GL_SAMPLER_BINDING, &unit1_sampler);
        glActiveTexture(GL_TEXTURE0);
        try {
            if (!steady_box) {
                char value[PROP_VALUE_MAX] = {};
                if (__system_property_get("debug.vrpp.steady.radius", value) > 0) steady_radius = std::clamp(atoi(value), 1, 12);
                if (__system_property_get("debug.vrpp.steady.epsilon", value) > 0) steady_epsilon = std::clamp(static_cast<float>(atof(value)), 1e-6f, 1.f);
                steady_pack_2d = program((std::string(warp_frame_2d) + "in highp vec2 uv;" + steady_pack_body).c_str());
                steady_pack_oes = program((std::string(warp_frame_oes) + "in highp vec2 uv;" + steady_pack_body).c_str());
                steady_box = program(steady_box_fragment);
                glGenSamplers(1, &steady_sampler);
                glSamplerParameteri(steady_sampler, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
                glSamplerParameteri(steady_sampler, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
                glSamplerParameteri(steady_sampler, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
                glSamplerParameteri(steady_sampler, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
                for (GLuint* texture : {&steady_packed, &steady_scratch, &steady_line}) {
                    image(*texture, w, h, GL_RGBA16F);
                    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
                }
                if (glGetError() != GL_NO_ERROR) throw std::runtime_error("steady edge allocation GL error");
            }
            // 0: luma and near of every model texel.
            target(steady_packed, w, h);
            const GLuint pack = slot.decoder_texture ? steady_pack_oes : steady_pack_2d;
            glUseProgram(pack);
            glBindSampler(0, steady_sampler);
            if (slot.decoder_texture) {
                glBindTexture(GL_TEXTURE_EXTERNAL_OES, slot.decoder_texture);
                glUniform2f(glGetUniformLocation(pack, "uv_scale"), slot.uv_scale[0], slot.uv_scale[1]);
            } else {
                glBindTexture(GL_TEXTURE_2D, slot.source());
                glUniform2f(glGetUniformLocation(pack, "uv_scale"), 1.f, 1.f);
            }
            glActiveTexture(GL_TEXTURE1); glBindTexture(GL_TEXTURE_2D, slot.alpha); glBindSampler(1, steady_sampler);
            glActiveTexture(GL_TEXTURE0);
            glUniform1i(glGetUniformLocation(pack, "source"), 0); glUniform1i(glGetUniformLocation(pack, "near_map"), 1);
            glUniform2i(glGetUniformLocation(pack, "model"), w, h);
            glUniform4fv(glGetUniformLocation(pack, "content"), 1, content_rect.data());
            glUniform2f(glGetUniformLocation(pack, "footprint"), 1.f / (w * content_rect[2]), 1.f / (h * content_rect[3]));
            glDrawArrays(GL_TRIANGLES, 0, 3);
            glBindSampler(0, 0);
            // 1-4: the two boxes, twice.
            glUseProgram(steady_box);
            glUniform1i(glGetUniformLocation(steady_box, "source"), 0); glUniform1i(glGetUniformLocation(steady_box, "packed"), 1);
            glUniform2i(glGetUniformLocation(steady_box, "size"), w, h);
            glUniform1i(glGetUniformLocation(steady_box, "radius"), steady_radius);
            glUniform1f(glGetUniformLocation(steady_box, "epsilon"), steady_epsilon);
            glActiveTexture(GL_TEXTURE1); glBindTexture(GL_TEXTURE_2D, steady_packed); glBindSampler(1, 0);
            glActiveTexture(GL_TEXTURE0);
            auto pass = [&](GLuint from, GLuint to, int tw, int ax, int ay, int stage) {
                target(to, tw, h);
                glBindTexture(GL_TEXTURE_2D, from);
                glUniform2i(glGetUniformLocation(steady_box, "axis"), ax, ay);
                glUniform1i(glGetUniformLocation(steady_box, "stage"), stage);
                glDrawArrays(GL_TRIANGLES, 0, 3);
            };
            pass(steady_packed, steady_scratch, w, 1, 0, 0);
            pass(steady_scratch, steady_line, w, 0, 1, 1);
            pass(steady_line, steady_scratch, w, 1, 0, 0);
            pass(steady_scratch, slot.alpha, w * 2, 0, 1, 2);
            if (glGetError() != GL_NO_ERROR) throw std::runtime_error("steady edge GL error");
            steady_maps++;
        } catch (const std::exception& failure) {
            steady_failed = true;
            while (glGetError() != GL_NO_ERROR) {}
            __android_log_print(ANDROID_LOG_WARN, "QuestRenderBridge", "2D->3D steady edges unavailable: %s", failure.what());
        }
        glActiveTexture(GL_TEXTURE1); glBindTexture(GL_TEXTURE_2D, static_cast<GLuint>(unit1_2d));
        glBindSampler(1, static_cast<GLuint>(unit1_sampler)); glActiveTexture(GL_TEXTURE0);
    }
    // Sets the stretch limit for later uploads (0: none) and re-limits the held map of `token` (0:
    // none), so a paused video follows the strength; like a rewarp, the shown texture is rewritten.
    void limit_near(jlong token, float shift) {
        near_limit_shift = shift;
        if (!token) return;
        current(); auto& slot = find(token);
        if (slot.phase != Phase::held || !slot.alpha || slot.near.empty()) return;
        State state;
        glBindTexture(GL_TEXTURE_2D, slot.alpha);
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, input_width*2, input_height, GL_RED, GL_UNSIGNED_BYTE, limited_near(slot.near).data());
        if (glGetError() != GL_NO_ERROR) throw std::runtime_error("Near limit GL error");
        steady_near(slot);
        glFlush();
    }
    // Extend the upload's completion fence: consumers never see a partially generated mip chain.
    GLuint prepare_portrait(jlong token, float lod_bias, const unsigned char* residual = nullptr) {
        current(); auto& slot = find(token);
        if (layout != 0 || slot.phase != Phase::held || (!slot.alpha_valid && !slot.alpha_fence))
            throw std::runtime_error("Portrait shape requires a fresh held mono Alpha upload");
        State state;
        if (!portrait_program) portrait_program = program(portrait_fragment);
        if (!slot.portrait) image(slot.portrait, input_width, input_height, GL_R8);
        if (!slot.portrait_mips) image(slot.portrait_mips, input_width, input_height, GL_R8, mip_levels(input_width, input_height));
        glBindFramebuffer(GL_FRAMEBUFFER, fbo);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, slot.alpha, 0);
        if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE)
            throw std::runtime_error("Portrait Alpha framebuffer incomplete");
        portrait_timer.start();
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, slot.portrait_mips);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR);
        glCopyTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, 0, 0, input_width, input_height);
        glGenerateMipmap(GL_TEXTURE_2D);
        // Godot's native-handle wrapper treats imported textures as single-level. Resolve the
        // three mip samples here; the renderer receives a normal R8 shape (one small extra pass).
        target(slot.portrait, input_width, input_height);
        glUseProgram(portrait_program);
        glUniform1i(glGetUniformLocation(portrait_program, "source"), 0);
        glUniform1f(glGetUniformLocation(portrait_program, "lod_bias"), lod_bias);
        glUniform1i(glGetUniformLocation(portrait_program, "residual_enabled"), residual ? 1 : 0);
        glUniform1i(glGetUniformLocation(portrait_program, "residual_map"), 1);
        TextureUnitOne unit;
        if (residual) {
            if (!portrait_residual_image) image(portrait_residual_image, 64, 64, GL_R8);
            glBindTexture(GL_TEXTURE_2D, portrait_residual_image);
            glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, 64, 64, GL_RED, GL_UNSIGNED_BYTE, residual);
        } else glBindTexture(GL_TEXTURE_2D, slot.portrait_mips);
        glDrawArrays(GL_TRIANGLES, 0, 3);
        portrait_timer.stop();
        check_gl("Portrait mip generation");
        if (slot.alpha_fence) glDeleteSync(slot.alpha_fence);
        slot.alpha_fence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
        if (!slot.alpha_fence) throw std::runtime_error("Portrait fence unavailable");
        slot.alpha_valid = false;
        slot.portrait_valid = true; ++portrait_frames;
        glFlush();
        return slot.portrait;
    }
    // Schedule the tiny mask readback behind Alpha, under its existing nonblocking publication fence.
    void stage_portrait_mask(jlong token) {
        current(); auto& slot = find(token);
        if (layout != 0 || slot.phase != Phase::held || !slot.alpha_fence || slot.alpha_valid)
            throw std::runtime_error("Portrait mask sampling requires fresh mono Alpha");
        State state;
        if (!portrait_mask_program) portrait_mask_program = program(portrait_mask_fragment);
        if (!portrait_mask_image) image(portrait_mask_image, 64, 64);
        target(portrait_mask_image, 64, 64); glUseProgram(portrait_mask_program);
        glBindTexture(GL_TEXTURE_2D, slot.alpha); glUniform1i(glGetUniformLocation(portrait_mask_program, "source"), 0);
        glDrawArrays(GL_TRIANGLES, 0, 3); glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
        if (!slot.portrait_mask_pbo) {
            glGenBuffers(1, &slot.portrait_mask_pbo);
            glBindBuffer(GL_PIXEL_PACK_BUFFER, slot.portrait_mask_pbo);
            glBufferData(GL_PIXEL_PACK_BUFFER, 64*64*4, nullptr, GL_STREAM_READ);
        } else glBindBuffer(GL_PIXEL_PACK_BUFFER, slot.portrait_mask_pbo);
        glReadPixels(0, 0, 64, 64, GL_RGBA, GL_UNSIGNED_BYTE, nullptr); check_gl("Portrait mask staging");
        glDeleteSync(slot.alpha_fence);
        slot.alpha_fence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
        if (!slot.alpha_fence) throw std::runtime_error("Portrait mask fence unavailable");
        slot.portrait_mask_staged = true; glFlush();
    }
    void read_portrait_mask(jlong token, unsigned char* output) {
        current(); auto& slot = find(token);
        if (layout != 0 || slot.phase != Phase::held || !slot.alpha_valid || !slot.portrait_mask_staged)
            throw std::runtime_error("Portrait mask requires a completed Alpha fence");
        State state;
        glBindBuffer(GL_PIXEL_PACK_BUFFER, slot.portrait_mask_pbo);
        const auto* rgba = static_cast<const unsigned char*>(glMapBufferRange(GL_PIXEL_PACK_BUFFER, 0, 64*64*4, GL_MAP_READ_BIT));
        if (!rgba) throw std::runtime_error("Portrait mask PBO unavailable");
        for (size_t i = 0; i < 64*64; ++i) output[i] = rgba[i*4];
        const bool valid = glUnmapBuffer(GL_PIXEL_PACK_BUFFER) == GL_TRUE;
        slot.portrait_mask_staged = false;
        if (!valid) throw std::runtime_error("Portrait mask PBO invalidated");
    }
    // One model-size crop when DA2 is idle (at most 3 Hz). The slot's colour lease stays held.
    void stage_portrait_input(jlong token, const float* rect, int iw, int ih) {
        current(); auto& slot = find(token);
        if (layout != 0 || slot.phase != Phase::held) throw std::runtime_error("Portrait input requires a held mono colour");
        State state;
        if (iw != portrait_input_width || ih != portrait_input_height) {
            glDeleteTextures(1, &portrait_input_image); portrait_input_image = 0;
            image(portrait_input_image, iw, ih); portrait_input_width = iw; portrait_input_height = ih;
        }
        target(portrait_input_image, iw, ih);
        const GLuint prog = bind_scale(slot, rect); eye_rect(prog, 0);
        glUniform2f(glGetUniformLocation(prog, "footprint"), 1.f/iw/rect[2], 1.f/ih/rect[3]);
        glDrawArrays(GL_TRIANGLES, 0, 3);
        const size_t pixels = static_cast<size_t>(iw)*ih;
        if (!portrait_input_pbo) glGenBuffers(1, &portrait_input_pbo);
        glBindBuffer(GL_PIXEL_PACK_BUFFER, portrait_input_pbo);
        // Orphan a cancelled controller's pending storage; GPU commands retain the old allocation.
        glBufferData(GL_PIXEL_PACK_BUFFER, pixels*4, nullptr, GL_STREAM_READ);
        glReadPixels(0, 0, iw, ih, GL_RGBA, GL_UNSIGNED_BYTE, nullptr); check_gl("Portrait crop staging");
        if (portrait_input_fence) glDeleteSync(portrait_input_fence);
        portrait_input_fence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
        if (!portrait_input_fence) throw std::runtime_error("Portrait crop fence unavailable");
        glFlush();
    }
    bool read_portrait_input(float* output) {
        current();
        if (!portrait_input_fence) return false;
        const auto ready = glClientWaitSync(portrait_input_fence, 0, 0);
        if (ready == GL_TIMEOUT_EXPIRED) return false;
        if (ready == GL_WAIT_FAILED) throw std::runtime_error("Portrait crop fence failed");
        State state; glBindBuffer(GL_PIXEL_PACK_BUFFER, portrait_input_pbo);
        const size_t pixels = static_cast<size_t>(portrait_input_width)*portrait_input_height;
        const auto* rgba = static_cast<const unsigned char*>(glMapBufferRange(GL_PIXEL_PACK_BUFFER, 0, pixels*4, GL_MAP_READ_BIT));
        if (!rgba) throw std::runtime_error("Portrait crop PBO unavailable");
        for (size_t i = 0; i < pixels; ++i) for (size_t c = 0; c < 3; ++c) output[c*pixels+i] = rgba[i*4+c]/255.f;
        const bool valid = glUnmapBuffer(GL_PIXEL_PACK_BUFFER) == GL_TRUE;
        glDeleteSync(portrait_input_fence); portrait_input_fence = nullptr;
        if (!valid) throw std::runtime_error("Portrait crop PBO invalidated");
        return true;
    }
    void release_text_input() {
        current();
        if (portrait_input_fence) glDeleteSync(portrait_input_fence);
        portrait_input_fence=nullptr;
        if (portrait_input_pbo) glDeleteBuffers(1,&portrait_input_pbo);
        portrait_input_pbo=0;
        if (portrait_input_image) glDeleteTextures(1,&portrait_input_image);
        portrait_input_image=0;portrait_input_width=portrait_input_height=0;
        for(auto& slot:slots) {slot.text_regions.clear();slot.text_weights.clear();}
    }
    // 2D->3D: renders the held color's stereo pair from its just-uploaded near map. shift is the
    // eye-width fraction of the full parallax, convergence the near value left on the screen plane.
    // Returns 0 when this GL or source cannot run it (the display keeps its shader parallax).
    // Edge-stretching pair eye size: the source scaled to fit 2560x2160 (`setprop debug.vrpp.warp.max_width N`
    // for A/B, read once per bridge).
    void video_warp_size() {
        if (warp_width) return;
        int cap = 2560;
        char value[PROP_VALUE_MAX] = {};
        if (__system_property_get("debug.vrpp.warp.max_width", value) > 0) cap = std::clamp(atoi(value), 640, 7680);
        const double scale = std::min({1.0, static_cast<double>(cap) / width, 2160.0 / height});
        warp_width = std::max(2, static_cast<int>(std::lround(width * scale)) & ~1);
        warp_height = std::max(2, static_cast<int>(std::lround(height * scale)) & ~1);
    }
    // Edge stretching as a stereo pair of the held color (see stretch_frame_body). 0: not enabled here.
    GLuint stretch(jlong token, float shift, float convergence) {
        current();
        if (stretch_native < 0) {
            char value[PROP_VALUE_MAX] = {};
            if (__system_property_get("debug.vrpp.stretch.native", value) > 0 && (value[0] == '0' || value[0] == '1')) {
                stretch_native = value[0] == '1';
            } else {
                const auto* renderer = reinterpret_cast<const char*>(glGetString(GL_RENDERER));
                const char* digits = renderer ? std::strpbrk(renderer, "0123456789") : nullptr;
                stretch_native = renderer && std::strstr(renderer, "Adreno") && digits && atoi(digits) >= 700;
            }
            if (__system_property_get("debug.vrpp.stretch.taps", value) > 0 && std::strcmp(value, "1") == 0) stretch_taps = 1;
        }
        if (!stretch_native || warp_failed || layout != 0) return 0;
        auto& slot = find(token);
        if (slot.phase != Phase::held || (!slot.alpha_fence && !slot.alpha_valid) || slot.near.empty())
            throw std::runtime_error("2D->3D stretch requires a held color with a fresh near map");
        video_warp_size();
        const int W = warp_width, H = warp_height;
        State state;
        GLint unit1_2d = 0, unit1_sampler = 0;
        glActiveTexture(GL_TEXTURE1); glGetIntegerv(GL_TEXTURE_BINDING_2D, &unit1_2d); glGetIntegerv(GL_SAMPLER_BINDING, &unit1_sampler);
        glBindSampler(1, 0); glActiveTexture(GL_TEXTURE0);
        try {
            if (!stretch_oes_prog) {
                stretch_2d_prog = program((std::string(warp_frame_2d) + stretch_frame_body).c_str());
                stretch_oes_prog = program((std::string(warp_frame_oes) + stretch_frame_body).c_str());
                glGenSamplers(1, &stretch_sampler);
                glSamplerParameteri(stretch_sampler, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
                glSamplerParameteri(stretch_sampler, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
                glSamplerParameteri(stretch_sampler, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
                glSamplerParameteri(stretch_sampler, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
            }
            if (!slot.warp) {
                image(slot.warp, W * 2, H);
                if (glGetError() != GL_NO_ERROR) throw std::runtime_error("2D->3D stretch allocation GL error");
            }
            frame_timer.start();
            target(slot.warp, W * 2, H);
            const GLuint prog = slot.decoder_texture ? stretch_oes_prog : stretch_2d_prog;
            glUseProgram(prog);
            if (slot.decoder_texture) {
                glBindTexture(GL_TEXTURE_EXTERNAL_OES, slot.decoder_texture);
                glUniform2f(glGetUniformLocation(prog, "uv_scale"), slot.uv_scale[0], slot.uv_scale[1]);
            } else {
                glBindTexture(GL_TEXTURE_2D, slot.source());
                glUniform2f(glGetUniformLocation(prog, "uv_scale"), 1.f, 1.f);
            }
            glActiveTexture(GL_TEXTURE1); glBindTexture(GL_TEXTURE_2D, slot.alpha); glBindSampler(1, stretch_sampler);
            glActiveTexture(GL_TEXTURE0);
            glUniform1i(glGetUniformLocation(prog, "source"), 0); glUniform1i(glGetUniformLocation(prog, "near_map"), 1);
            glUniform1i(glGetUniformLocation(prog, "four_taps"), stretch_taps == 4 ? 1 : 0);
            glUniform2i(glGetUniformLocation(prog, "size"), W, H);
            glUniform2i(glGetUniformLocation(prog, "model"), input_width, input_height);
            glUniform4fv(glGetUniformLocation(prog, "content"), 1, content_rect.data());
            glUniform1f(glGetUniformLocation(prog, "shift"), shift);
            glUniform1f(glGetUniformLocation(prog, "convergence"), convergence);
            glUniform2f(glGetUniformLocation(prog, "footprint"), W < width ? 0.25f / W : 0.f, H < height ? 0.25f / H : 0.f);
            const auto& regions = slot.text_regions;
            glUniform1i(glGetUniformLocation(prog, "text_count"), static_cast<int>(regions.size() / 4));
            if (!regions.empty()) glUniform4fv(glGetUniformLocation(prog, "text_regions"), static_cast<GLsizei>(regions.size() / 4), regions.data());
            std::array<float, 8> opacity; opacity.fill(1.f);
            std::copy(slot.text_weights.begin(), slot.text_weights.end(), opacity.begin());
            glUniform4fv(glGetUniformLocation(prog, "text_weights0"), 1, opacity.data());
            glUniform4fv(glGetUniformLocation(prog, "text_weights1"), 1, opacity.data() + 4);
            glDrawArrays(GL_TRIANGLES, 0, 3);
            frame_timer.stop();
            if (glGetError() != GL_NO_ERROR) throw std::runtime_error("2D->3D stretch GL error");
            if (slot.alpha_fence) glDeleteSync(slot.alpha_fence);
            slot.alpha_fence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
            if (!slot.alpha_fence) throw std::runtime_error("2D->3D stretch fence unavailable");
            glFlush();
            stretch_frames++;
        } catch (const std::exception& failure) {
            warp_failed = true;
            __android_log_print(ANDROID_LOG_WARN, "QuestRenderBridge", "2D->3D stretch unavailable: %s", failure.what());
        }
        glActiveTexture(GL_TEXTURE1); glBindTexture(GL_TEXTURE_2D, static_cast<GLuint>(unit1_2d));
        glBindSampler(1, static_cast<GLuint>(unit1_sampler)); glActiveTexture(GL_TEXTURE0);
        while (glGetError() != GL_NO_ERROR) {}
        return warp_failed ? 0 : slot.warp;
    }
    GLuint warp(jlong token, float shift, float convergence, GLuint matte = 0, const float* matte_content = nullptr) {
        current(); auto& slot = find(token);
        if (slot.phase != Phase::held || (!slot.alpha_fence && !slot.alpha_valid) || slot.near.empty())
            throw std::runtime_error("2D->3D warp requires a held color with a fresh near map");
        if (warp_failed || layout != 0) return 0;
        if (width > 2560 || height > 2160) {
            // 4K: off by default since 5e94fee4 (the compute fill at a 2560 pair showed 38 of 60 fps).
            // `setprop debug.vrpp.fill.4k 1` warps at the edge-stretching pair size for A/B.
            if (fill_4k < 0) {
                char value[PROP_VALUE_MAX] = {};
                fill_4k = __system_property_get("debug.vrpp.fill.4k", value) > 0 && std::strcmp(value, "1") == 0 ? 1 : 0;
            }
            if (fill_4k != 1) return 0;
            video_warp_size();
        } else { warp_width = width; warp_height = height; }
        State state;
        GLint unit1_2d = 0, unit1_sampler = 0, ssbo = 0, ssbo0 = 0, ssbo1 = 0, image0 = 0;
        glActiveTexture(GL_TEXTURE1); glGetIntegerv(GL_TEXTURE_BINDING_2D, &unit1_2d); glGetIntegerv(GL_SAMPLER_BINDING, &unit1_sampler);
        glBindSampler(1, 0); glActiveTexture(GL_TEXTURE0);
        glGetIntegerv(GL_SHADER_STORAGE_BUFFER_BINDING, &ssbo); glGetIntegeri_v(GL_SHADER_STORAGE_BUFFER_BINDING, 0, &ssbo0);
        glGetIntegeri_v(GL_SHADER_STORAGE_BUFFER_BINDING, 1, &ssbo1);
        glGetIntegeri_v(GL_IMAGE_BINDING_NAME, 0, &image0);
        GLint unit2_2d = 0, unit2_sampler = 0;
        glActiveTexture(GL_TEXTURE2); glGetIntegerv(GL_TEXTURE_BINDING_2D, &unit2_2d); glGetIntegerv(GL_SAMPLER_BINDING, &unit2_sampler);
        glBindSampler(2, 0); glActiveTexture(GL_TEXTURE0);
        GLuint result = 0;
        try { result = render_warp(slot, shift, convergence, -1.f, 0, matte, matte_content); }
        catch (const std::exception& failure) {
            warp_failed = true;
            __android_log_print(ANDROID_LOG_WARN, "QuestRenderBridge", "2D->3D warp unavailable: %s", failure.what());
        }
        glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, static_cast<GLuint>(ssbo0));
        glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 1, static_cast<GLuint>(ssbo1)); glBindBuffer(GL_SHADER_STORAGE_BUFFER, static_cast<GLuint>(ssbo));
        if (!image0) glBindImageTexture(0, 0, 0, GL_FALSE, 0, GL_READ_ONLY, GL_RGBA8);
        glActiveTexture(GL_TEXTURE1); glBindTexture(GL_TEXTURE_2D, static_cast<GLuint>(unit1_2d));
        glBindSampler(1, static_cast<GLuint>(unit1_sampler)); glActiveTexture(GL_TEXTURE0);
        glActiveTexture(GL_TEXTURE2); glBindTexture(GL_TEXTURE_2D, static_cast<GLuint>(unit2_2d));
        glBindSampler(2, static_cast<GLuint>(unit2_sampler)); glActiveTexture(GL_TEXTURE0);
        while (glGetError() != GL_NO_ERROR) {}
        return result;
    }
    // Debug inspection: `setprop debug.vrpp.warp.dump N` writes the next pair (as PPM) to the app's
    // external files directory; each new N writes once more, 0 turns it off.
    std::string dumped;
    void dump_warp() { // reads the bound pair framebuffer
        char value[PROP_VALUE_MAX] = {};
        if (__system_property_get("debug.vrpp.warp.dump", value) <= 0 || std::strcmp(value, "0") == 0 || dumped == value) return;
        dumped = value;
        const int W2 = width * 2;
        std::vector<unsigned char> rgba(static_cast<size_t>(W2) * height * 4);
        glReadPixels(0, 0, W2, height, GL_RGBA, GL_UNSIGNED_BYTE, rgba.data());
        const std::string path = std::string("/sdcard/Android/data/com.wapok.thru3d/files/warp_") + value + ".ppm";
        if (FILE* file = std::fopen(path.c_str(), "wb")) {
            std::fprintf(file, "P6\n%d %d\n255\n", W2, height);
            for (size_t i = 0; i < rgba.size(); i += 4) std::fwrite(&rgba[i], 1, 3, file);
            std::fclose(file);
        }
    }
    // Still edge stretching: the video stretch view's inverse warp (stretch_frame_body) over the still's
    // gradient-limited near map, at the pair's full size. Holes never open, so nothing is filled.
    GLuint photo_stretch(Slot& slot, float half, float convergence, int photo_rotation) {
        if (!stretch_2d_prog) stretch_2d_prog = program((std::string(warp_frame_2d) + stretch_frame_body).c_str());
        const int output_width = photo_rotation % 2 ? height : width;
        const int output_height = photo_rotation % 2 ? width : height;
        if (!slot.warp) {
            image(slot.warp, output_width * 2, output_height);
            if (glGetError() != GL_NO_ERROR) throw std::runtime_error("Photo stretch allocation GL error");
        }
        target(slot.warp, output_width * 2, output_height);
        const GLuint prog = stretch_2d_prog;
        glUseProgram(prog);
        glBindTexture(GL_TEXTURE_2D, slot.source());
        glActiveTexture(GL_TEXTURE1); glBindTexture(GL_TEXTURE_2D, slot.alpha);
        // The still's own near map: one linear tap, as the video stretch view's sampler.
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glActiveTexture(GL_TEXTURE0);
        glUniform1i(glGetUniformLocation(prog, "source"), 0); glUniform1i(glGetUniformLocation(prog, "near_map"), 1);
        glUniform2f(glGetUniformLocation(prog, "uv_scale"), 1.f, 1.f);
        glUniform1i(glGetUniformLocation(prog, "four_taps"), 0);
        glUniform2f(glGetUniformLocation(prog, "footprint"), 0.f, 0.f);
        glUniform2i(glGetUniformLocation(prog, "size"), width, height);
        glUniform2i(glGetUniformLocation(prog, "model"), input_width, input_height);
        glUniform4fv(glGetUniformLocation(prog, "content"), 1, content_rect.data());
        glUniform1f(glGetUniformLocation(prog, "shift"), 2.f * half / width);
        glUniform1f(glGetUniformLocation(prog, "convergence"), convergence);
        glUniform1i(glGetUniformLocation(prog, "photo_rotation"), photo_rotation);
        glUniform1i(glGetUniformLocation(prog, "text_count"), 0);
        glDrawArrays(GL_TRIANGLES, 0, 3);
        if (glGetError() != GL_NO_ERROR) throw std::runtime_error("Photo stretch GL error");
        return slot.warp;
    }
    GLuint render_warp(Slot& slot, float shift, float convergence, float photo_half = -1.f, int photo_rotation = 0,
                       GLuint matte = 0, const float* matte_content = nullptr) {
        const auto& text_regions=slot.text_regions;
        const auto& text_weights=slot.text_weights;
        GLint major = 0, minor = 0; glGetIntegerv(GL_MAJOR_VERSION, &major); glGetIntegerv(GL_MINOR_VERSION, &minor);
        if (major * 10 + minor < 31) throw std::runtime_error("OpenGL ES 3.1 compute unavailable");
        // Video warps at warp_width x warp_height (the source, or scaled to fit the realtime budget at 4K);
        // a still keeps its own size.
        const int W_ = photo_half >= 0.f ? width : warp_width, H_ = photo_half >= 0.f ? height : warp_height;
        const int W2 = W_ * 2;
        // Stills time each pass for the depth log (glFinish between them; the call waits for its readback anyway).
        const bool timed = photo_half >= 0.f;
        auto pass_started = std::chrono::steady_clock::now();
        photo_passes.clear();
        const auto pass = [&](const char* name) {
            if (!timed) return;
            glFinish();
            const auto now = std::chrono::steady_clock::now();
            char text[48]; std::snprintf(text, sizeof(text), "%s%s=%.1f", photo_passes.empty() ? "" : " ", name,
                std::chrono::duration<double, std::milli>(now - pass_started).count());
            photo_passes += text; pass_started = now;
        };
        // Programs may come from an earlier still's bridge (photo_stereo keeps them); buffers are per size.
        if (!warp_frame_oes_prog) {
            warp_clear_prog = compute_program(warp_clear); warp_scatter_prog = compute_program(warp_scatter);
            warp_keep_prog = compute_program((std::string(warp_rim) + warp_keep).c_str());
            warp_classify_prog = compute_program((std::string(warp_rim) + warp_classify).c_str());
            warp_frame_2d_prog = warp_frame_program(warp_frame_2d); warp_frame_oes_prog = warp_frame_program(warp_frame_oes);
        }
        if (fill_v2 < 0) {
            char value[PROP_VALUE_MAX] = {};
            fill_v2 = __system_property_get("debug.vrpp.fill.v2", value) > 0 && std::strcmp(value, "0") == 0 ? 0 : 1;
            fill_position = __system_property_get("debug.vrpp.fill.position", value) > 0 && std::strcmp(value, "0") == 0 ? 0 : 1;
        }
        const bool backward = fill_v2 == 1 && text_regions.empty() && photo_half < 0.f;
        const int position_on = fill_position == 1 && text_regions.empty() ? 1 : 0;
        if (!warp_map) {
            image(warp_map, W2, H_, GL_RGBA16F);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
            if (glGetError() != GL_NO_ERROR) throw std::runtime_error("2D->3D warp allocation GL error");
        }
        if (!warp_keys && !backward) {
            glGenBuffers(1, &warp_keys); glBindBuffer(GL_SHADER_STORAGE_BUFFER, warp_keys);
            glBufferData(GL_SHADER_STORAGE_BUFFER, static_cast<GLsizeiptr>(W2) * H_ * 4, nullptr, GL_DYNAMIC_COPY);
            glGenBuffers(1, &warp_kept); glBindBuffer(GL_SHADER_STORAGE_BUFFER, warp_kept);
            glBufferData(GL_SHADER_STORAGE_BUFFER, photo_half >= 0.f ? static_cast<GLsizeiptr>((W2 + 31) / 32) * H_ * 2 * 4 : 4, nullptr, GL_DYNAMIC_COPY);
            if (glGetError() != GL_NO_ERROR) throw std::runtime_error("2D->3D warp allocation GL error");
        }
        // PTMediaServer _max_disparity_pixels: max(2, min(96, W * 0.035 * strength)); each eye moves half.
        const float half = photo_half >= 0.f ? photo_half : (shift > 0.f ? std::max(2.f, std::min(96.f, W_ * shift)) * 0.5f : 0.f);
        if (warp_time < 0) {
            char value[PROP_VALUE_MAX] = {};
            warp_time = __system_property_get("debug.vrpp.warp.time", value) > 0 && std::strcmp(value, "1") == 0 ? 1 : 0;
        }
        const bool wall = warp_time == 1 && !timed;
        auto wall_started = std::chrono::steady_clock::now();
        if (wall) { glFinish(); wall_started = std::chrono::steady_clock::now(); }
        if (slot.near != map_near || half != map_half || convergence != map_convergence || map_text != text_regions || map_text_weights != text_weights) {
            map_timer.start();
            const auto uniforms = [&](GLuint prog) {
                glUseProgram(prog);
                glUniform1i(glGetUniformLocation(prog, "near_map"), 0);
                glUniform1i(glGetUniformLocation(prog, "snap_map"), 3);
                glUniform1i(glGetUniformLocation(prog, "split"), snap_texture ? 1 : 0);
                glUniform1i(glGetUniformLocation(prog, "position"), position_on);
                glUniform1i(glGetUniformLocation(prog, "window_map"), 4);
                glUniform1i(glGetUniformLocation(prog, "cont"), position_on);
                glUniform2i(glGetUniformLocation(prog, "size"), W_, H_);
                glUniform2i(glGetUniformLocation(prog, "model"), input_width, input_height);
                glUniform4fv(glGetUniformLocation(prog, "content"), 1, content_rect.data());
                glUniform2f(glGetUniformLocation(prog, "shift"), half, convergence);
                glUniform1i(glGetUniformLocation(prog, "text_count"), static_cast<int>(text_regions.size()/4));
                if (!text_regions.empty()) glUniform4fv(glGetUniformLocation(prog, "text_regions"), static_cast<GLsizei>(text_regions.size()/4), text_regions.data());
                std::array<float,8> opacity;opacity.fill(1.f);
                std::copy(text_weights.begin(),text_weights.end(),opacity.begin());
                glUniform4fv(glGetUniformLocation(prog,"text_weights0"),1,opacity.data());
                glUniform4fv(glGetUniformLocation(prog,"text_weights1"),1,opacity.data()+4);
            };
            const float columns = content_rect[2] * input_width / W_; // model columns per pair px
            if (backward || position_on) {
                if (!fill_window_prog) {
                    fill_window_prog = program(fill_window_fragment);
                    image(fill_window, input_width, input_height, GL_RGBA8);
                    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
                }
                // The snap window over the map winners are snapped from (stills: the unlimited one).
                target(fill_window, input_width, input_height);
                glUseProgram(fill_window_prog);
                glBindTexture(GL_TEXTURE_2D, snap_texture ? snap_texture : slot.alpha);
                glUniform1i(glGetUniformLocation(fill_window_prog, "near_map"), 0);
                glUniform2i(glGetUniformLocation(fill_window_prog, "model"), input_width, input_height);
                glUniform4fv(glGetUniformLocation(fill_window_prog, "content"), 1, content_rect.data());
                glUniform1i(glGetUniformLocation(fill_window_prog, "win"), std::max(1, static_cast<int>(std::ceil(6.f * columns))));
                glUniform1i(glGetUniformLocation(fill_window_prog, "reach"), static_cast<int>(std::ceil((half + 1.f) * columns)) + 1);
                glDrawArrays(GL_TRIANGLES, 0, 3);
                glActiveTexture(GL_TEXTURE4); glBindTexture(GL_TEXTURE_2D, fill_window); glActiveTexture(GL_TEXTURE0);
            }
            if (backward) {
                if (!fill_map_prog) fill_map_prog = program(fill_map_fragment);
                target(warp_map, W2, H_);
                glUseProgram(fill_map_prog);
                glBindTexture(GL_TEXTURE_2D, slot.alpha);
                glActiveTexture(GL_TEXTURE1); glBindTexture(GL_TEXTURE_2D, fill_window); glActiveTexture(GL_TEXTURE0);
                glUniform1i(glGetUniformLocation(fill_map_prog, "near_map"), 0); glUniform1i(glGetUniformLocation(fill_map_prog, "window"), 1);
                glUniform2i(glGetUniformLocation(fill_map_prog, "size"), W_, H_);
                glUniform2i(glGetUniformLocation(fill_map_prog, "model"), input_width, input_height);
                glUniform4fv(glGetUniformLocation(fill_map_prog, "content"), 1, content_rect.data());
                glUniform2f(glGetUniformLocation(fill_map_prog, "shift"), half, convergence);
                glUniform1i(glGetUniformLocation(fill_map_prog, "cont"), position_on);
                glDrawArrays(GL_TRIANGLES, 0, 3);
                pass("fill");
            } else {
            // Stills' own context (photo_stereo): unit 3 carries the unlimited map, video binds nothing there.
            if (snap_texture) { glActiveTexture(GL_TEXTURE3); glBindTexture(GL_TEXTURE_2D, snap_texture); glActiveTexture(GL_TEXTURE0); }
            glBindTexture(GL_TEXTURE_2D, slot.alpha);
            glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, warp_keys);
            glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 1, warp_kept);
            const int count = W2 * H_;
            const int rim = std::max(2, static_cast<int>(std::lround(W_ / 120.0)));
            const int bridge = photo_half >= 0.f ? 1 : 0;
            uniforms(warp_clear_prog); glUniform1i(glGetUniformLocation(warp_clear_prog, "count"), count);
            glDispatchCompute(static_cast<GLuint>((count + 255) / 256), 1, 1);
            glMemoryBarrier(GL_SHADER_STORAGE_BARRIER_BIT);
            uniforms(warp_scatter_prog);
            glDispatchCompute(static_cast<GLuint>((W_ + 7) / 8), static_cast<GLuint>((H_ + 7) / 8), 1);
            glMemoryBarrier(GL_SHADER_STORAGE_BARRIER_BIT);
            pass("scatter");
            if (bridge) {
                uniforms(warp_keep_prog);
                glUniform1i(glGetUniformLocation(warp_keep_prog, "rim"), rim);
                glUniform1i(glGetUniformLocation(warp_keep_prog, "bridge"), 1);
                for (int stage = 0; stage < 2; ++stage) { // holes, then the kept winners they decide
                    glUniform1i(glGetUniformLocation(warp_keep_prog, "stage"), stage);
                    glDispatchCompute(static_cast<GLuint>(((W2 + 31) / 32 + 63) / 64), static_cast<GLuint>(H_), 1);
                    glMemoryBarrier(GL_SHADER_STORAGE_BARRIER_BIT);
                }
                pass("keep");
            }
            uniforms(warp_classify_prog);
            glUniform1i(glGetUniformLocation(warp_classify_prog, "rim"), rim);
            glUniform1i(glGetUniformLocation(warp_classify_prog, "fg_win"), std::max(2, static_cast<int>(std::lround(W_ / 240.0))));
            glUniform1i(glGetUniformLocation(warp_classify_prog, "bridge"), bridge);
            glBindImageTexture(0, warp_map, 0, GL_FALSE, 0, GL_WRITE_ONLY, GL_RGBA16F);
            glDispatchCompute(static_cast<GLuint>((W2 + 7) / 8), static_cast<GLuint>((H_ + 7) / 8), 1);
            // Position stretch also renders over this map (fill_rows_fragment) after reading it.
            glMemoryBarrier(GL_TEXTURE_FETCH_BARRIER_BIT | (position_on ? GL_FRAMEBUFFER_BARRIER_BIT : 0));
            pass("classify");
            }
            if (position_on) {
                if (!fill_run_prog) { fill_run_prog = program(fill_run_fragment); fill_rows_prog = program(fill_rows_fragment); }
                if (!warp_map2) {
                    image(warp_map2, W2, H_, GL_RGBA16F);
                    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
                }
                glBindImageTexture(0, 0, 0, GL_FALSE, 0, GL_READ_ONLY, GL_RGBA8); // the classify left the map on image unit 0
                const int rim = std::max(2, static_cast<int>(std::lround(W_ / 120.0)));
                target(warp_map2, W2, H_);
                glUseProgram(fill_run_prog);
                glBindTexture(GL_TEXTURE_2D, warp_map);
                glUniform1i(glGetUniformLocation(fill_run_prog, "map"), 0);
                glUniform2i(glGetUniformLocation(fill_run_prog, "size"), W_, H_);
                glUniform1i(glGetUniformLocation(fill_run_prog, "reach"), static_cast<int>(std::ceil(2.f * half)) + rim + 24);
                glDrawArrays(GL_TRIANGLES, 0, 3);
                target(warp_map, W2, H_);
                glUseProgram(fill_rows_prog);
                glBindTexture(GL_TEXTURE_2D, warp_map2);
                glUniform1i(glGetUniformLocation(fill_rows_prog, "map"), 0);
                glUniform2i(glGetUniformLocation(fill_rows_prog, "size"), W_, H_);
                glUniform1i(glGetUniformLocation(fill_rows_prog, "rows"), 10);
                glDrawArrays(GL_TRIANGLES, 0, 3);
                pass("position");
            }
            glActiveTexture(GL_TEXTURE4); glBindTexture(GL_TEXTURE_2D, 0); glActiveTexture(GL_TEXTURE0);
            map_timer.stop();
            if (glGetError() != GL_NO_ERROR) throw std::runtime_error("2D->3D warp map GL error");
            map_near = slot.near; map_text = text_regions; map_text_weights = text_weights; map_half = half; map_convergence = convergence; warp_maps++;
            if (wall) {
                glFinish(); const auto now = std::chrono::steady_clock::now();
                warp_time_map += std::chrono::duration<double, std::milli>(now - wall_started).count(); warp_time_maps++; wall_started = now;
            }
        }
        const int output_width = photo_rotation % 2 ? H_ : W_;
        const int output_height = photo_rotation % 2 ? W_ : H_;
        if (!slot.warp) {
            image(slot.warp, output_width * 2, output_height);
            if (glGetError() != GL_NO_ERROR) throw std::runtime_error("2D->3D stereo allocation GL error");
        }
        frame_timer.start();
        target(slot.warp, output_width * 2, output_height);
        const GLuint prog = slot.decoder_texture ? warp_frame_oes_prog : warp_frame_2d_prog;
        glUseProgram(prog);
        if (slot.decoder_texture) {
            glBindTexture(GL_TEXTURE_EXTERNAL_OES, slot.decoder_texture);
            glUniform2f(glGetUniformLocation(prog, "uv_scale"), slot.uv_scale[0], slot.uv_scale[1]);
        } else {
            glBindTexture(GL_TEXTURE_2D, slot.source());
            glUniform2f(glGetUniformLocation(prog, "uv_scale"), 1.f, 1.f);
        }
        glActiveTexture(GL_TEXTURE1); glBindTexture(GL_TEXTURE_2D, warp_map); glActiveTexture(GL_TEXTURE0);
        glUniform1i(glGetUniformLocation(prog, "source"), 0); glUniform1i(glGetUniformLocation(prog, "map"), 1);
        glUniform2i(glGetUniformLocation(prog, "size"), W_, H_);
        glUniform1i(glGetUniformLocation(prog, "photo_rotation"), photo_rotation);
        glUniform2f(glGetUniformLocation(prog, "footprint"), W_ < width ? 0.25f / W_ : 0.f, H_ < height ? 0.25f / H_ : 0.f);
        glUniform1i(glGetUniformLocation(prog, "source_alpha_enabled"), matte ? 1 : 0);
        glUniform1i(glGetUniformLocation(prog, "source_alpha"), 2);
        if (matte) {
            glActiveTexture(GL_TEXTURE2); glBindTexture(GL_TEXTURE_2D, matte); glActiveTexture(GL_TEXTURE0);
            glUniform4fv(glGetUniformLocation(prog, "alpha_content"), 1, matte_content);
        }
        glDrawArrays(GL_TRIANGLES, 0, 3);
        frame_timer.stop();
        pass("frame");
        if (wall) {
            glFinish();
            warp_time_frame += std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - wall_started).count();
            if (++warp_time_frames == 48) {
                __android_log_print(ANDROID_LOG_INFO, "QuestRenderBridge", "warp timing %dx%d maps=%d map_ms=%.2f frame_ms=%.2f",
                                    W_, H_, warp_time_maps, warp_time_maps ? warp_time_map / warp_time_maps : 0.0, warp_time_frame / 48);
                warp_time_map = warp_time_frame = 0; warp_time_maps = warp_time_frames = 0;
            }
        }
        dump_warp();
        if (glGetError() != GL_NO_ERROR) throw std::runtime_error("2D->3D warp GL error");
        // The pair is ready when the warp is complete, not just the mask upload.
        if (slot.alpha_fence) glDeleteSync(slot.alpha_fence);
        slot.alpha_fence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
        if (!slot.alpha_fence) throw std::runtime_error("2D->3D warp fence unavailable");
        glFlush();
        warp_frames++;
        return slot.warp;
    }
    bool alpha_ready(Slot& slot) {
        if (slot.phase != Phase::held) return false;
        if (slot.alpha_valid) return true;
        if (!slot.alpha_fence) return false;
        const auto result = glClientWaitSync(slot.alpha_fence, 0, 0);
        if (result == GL_WAIT_FAILED) throw std::runtime_error("Alpha upload fence failed");
        if (result != GL_ALREADY_SIGNALED && result != GL_CONDITION_SATISFIED) return false;
        glDeleteSync(slot.alpha_fence); slot.alpha_fence = nullptr; slot.alpha_valid = true;
        return true;
    }
};
std::mutex registry_mutex;
std::unordered_map<jlong, std::unique_ptr<Bridge>> registry;
// Independent of processing sessions and decoder surfaces. Only one transition
// can be displayed; no resource growth when many seek requests are coalesced.
struct FrozenFrame final {
    const EGLContext context = eglGetCurrentContext();
    GLuint color = 0, alpha = 0, portrait = 0;
    ~FrozenFrame() {
        if (context != eglGetCurrentContext()) return;
        glDeleteTextures(1, &color); glDeleteTextures(1, &alpha); glDeleteTextures(1, &portrait);
    }
};
std::unordered_map<jlong, std::unique_ptr<FrozenFrame>> frozen_frames;
jlong sequence = 0, token_sequence = 0;
Bridge& find(jlong handle) {
    const auto it = registry.find(handle);
    if (it == registry.end()) throw std::runtime_error("Render bridge closed/unknown handle");
    it->second->current(); return *it->second;
}
void error(JNIEnv* env, const char* message) {
    if (!env->ExceptionCheck()) { const auto type = env->FindClass("java/lang/IllegalStateException"); if (type) env->ThrowNew(type, message); }
}
void* direct_buffer(JNIEnv* env, jobject buffer, size_t bytes, bool writable) {
    if (!buffer || env->GetDirectBufferCapacity(buffer) != static_cast<jlong>(bytes))
        throw std::runtime_error("Render bridge exact-size direct CHW buffer required");
    auto* address = env->GetDirectBufferAddress(buffer);
    if (!address) throw std::runtime_error("Render bridge direct buffer address invalid");
    const auto type = env->GetObjectClass(buffer);
    const auto method = type ? env->GetMethodID(type, "isReadOnly", "()Z") : nullptr;
    const bool readonly = method && env->CallBooleanMethod(buffer, method) == JNI_TRUE;
    if (type) env->DeleteLocalRef(type);
    if (!method || env->ExceptionCheck() || (writable && readonly)) throw std::runtime_error("Render bridge direct output must be writable");
    return address;
}
float* float_buffer(JNIEnv* env, jobject buffer, size_t bytes, bool writable = true) {
    auto* address = static_cast<float*>(direct_buffer(env, buffer, bytes, writable));
    if (reinterpret_cast<uintptr_t>(address) % alignof(float) != 0)
        throw std::runtime_error("Render bridge float buffer alignment invalid");
    return address;
}

// Still photos use the very same compute/fragment passes as video, once per strength, on a worker
// context of their own (no inference or readback on Godot's GL thread). The context and the warp
// programs are kept between photos: building them took 50-110 ms a photo on Quest 3. Once Godot's
// context is known (photoShareContext, from its GL thread) the worker context shares its objects:
// a finished pair then stays a GPU texture the picture layer copies in one step, instead of 22 frames
// of band uploads from the CPU image.
struct PhotoGpu final {
    std::mutex context_mutex; // the worker context: one still at a time
    EGLDisplay display = EGL_NO_DISPLAY;
    EGLContext context = EGL_NO_CONTEXT, shared_with = EGL_NO_CONTEXT;
    EGLSurface surface = EGL_NO_SURFACE;
    bool sharing = false;
    std::array<GLuint, 7> programs{}; // Bridge warp and stretch programs, see keep_programs
    struct Pair { GLuint texture = 0; int width = 0, height = 0; EGLContext group = EGL_NO_CONTEXT; GLsync used = nullptr; int busy = 0; };
    std::mutex pairs_mutex; // Godot's thread copies pairs while the worker makes the next one
    std::map<jint, Pair> pairs; // by token, oldest first
    jint next_token = 0;
};
PhotoGpu photo_gpu;
std::atomic<EGLDisplay> godot_display{EGL_NO_DISPLAY};
std::atomic<EGLContext> godot_context{EGL_NO_CONTEXT};
// The shown pair and one prefetched neighbour each side: 3 x ~45 MB for a 4 MP eye.
constexpr size_t kPhotoPairs = 3;

// Deletes a pair after Godot's last copy of it completed. Worker context current.
void delete_pair(PhotoGpu::Pair& pair) {
    if (pair.used) {
        glClientWaitSync(pair.used, 0, 200'000'000);
        glDeleteSync(pair.used);
    }
    glDeleteTextures(1, &pair.texture);
}
// Pairs Godot is not copying now, all or past kPhotoPairs - keep; then delete them outside the lock.
void evict_pairs(size_t keep) {
    std::vector<PhotoGpu::Pair> victims;
    {
        std::lock_guard<std::mutex> lock(photo_gpu.pairs_mutex);
        for (auto it = photo_gpu.pairs.begin(); it != photo_gpu.pairs.end() && photo_gpu.pairs.size() > keep;) {
            if (it->second.busy) { ++it; continue; }
            victims.push_back(it->second); it = photo_gpu.pairs.erase(it);
        }
    }
    for (auto& pair : victims) delete_pair(pair);
}

// Makes the kept worker context current for one still (context_mutex held), (re)creating it when
// Godot's context appeared or changed; restores the thread's previous context afterwards.
struct PhotoCurrent final {
    EGLDisplay previous_display = eglGetCurrentDisplay();
    EGLContext previous_context = eglGetCurrentContext();
    EGLSurface previous_draw = eglGetCurrentSurface(EGL_DRAW), previous_read = eglGetCurrentSurface(EGL_READ);
    EGLenum previous_api = eglQueryAPI();
    explicit PhotoCurrent(PhotoGpu& gpu) {
        try {
            const EGLContext share = godot_context.load();
            if (gpu.context != EGL_NO_CONTEXT && gpu.shared_with == share) {
                if (!eglBindAPI(EGL_OPENGL_ES_API) || !eglMakeCurrent(gpu.display, gpu.surface, gpu.surface, gpu.context))
                    throw std::runtime_error("Photo EGL context unavailable");
                return;
            }
            drop(gpu);
            const EGLDisplay known = godot_display.load();
            gpu.display = known != EGL_NO_DISPLAY ? known : eglGetDisplay(EGL_DEFAULT_DISPLAY);
            if (gpu.display == EGL_NO_DISPLAY || !eglInitialize(gpu.display, nullptr, nullptr)) throw std::runtime_error("Photo EGL unavailable");
            const EGLint config_attributes[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
                EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE};
            EGLConfig config{}; EGLint count = 0;
            if (!eglChooseConfig(gpu.display, config_attributes, &config, 1, &count) || count != 1 || !eglBindAPI(EGL_OPENGL_ES_API))
                throw std::runtime_error("Photo EGL configuration unavailable");
            const EGLint surface_attributes[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE};
            const EGLint context_attributes[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
            gpu.surface = eglCreatePbufferSurface(gpu.display, config, surface_attributes);
            gpu.context = share != EGL_NO_CONTEXT ? eglCreateContext(gpu.display, config, share, context_attributes) : EGL_NO_CONTEXT;
            gpu.sharing = gpu.context != EGL_NO_CONTEXT;
            // Without Godot's context (or if sharing is refused) the pair still goes through its CPU image.
            if (!gpu.sharing) gpu.context = eglCreateContext(gpu.display, config, EGL_NO_CONTEXT, context_attributes);
            gpu.shared_with = share;
            if (gpu.surface == EGL_NO_SURFACE || gpu.context == EGL_NO_CONTEXT || !eglMakeCurrent(gpu.display, gpu.surface, gpu.surface, gpu.context))
                throw std::runtime_error("Photo EGL context unavailable");
            if (share != EGL_NO_CONTEXT && !gpu.sharing) __android_log_print(ANDROID_LOG_WARN, "QuestPhotoStereo", "Context sharing with Godot refused");
        } catch (...) { drop(gpu); restore(); throw; }
    }
    ~PhotoCurrent() { restore(); }
    void restore() const {
        eglBindAPI(previous_api);
        if (previous_display != EGL_NO_DISPLAY) eglMakeCurrent(previous_display, previous_draw, previous_read, previous_context);
        else if (photo_gpu.display != EGL_NO_DISPLAY) eglMakeCurrent(photo_gpu.display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    }
    // Objects shared with Godot outlive a destroyed context: delete the pairs and programs first.
    static void drop(PhotoGpu& gpu) {
        if (gpu.context != EGL_NO_CONTEXT && eglMakeCurrent(gpu.display, gpu.surface, gpu.surface, gpu.context)) {
            evict_pairs(0);
            for (auto& program : gpu.programs) if (program) glDeleteProgram(program);
            eglMakeCurrent(gpu.display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        }
        {
            std::lock_guard<std::mutex> lock(gpu.pairs_mutex);
            gpu.pairs.clear(); // only pairs Godot was copying at a context change: their names die with it
        }
        gpu.programs.fill(0);
        if (gpu.context != EGL_NO_CONTEXT) eglDestroyContext(gpu.display, gpu.context);
        if (gpu.surface != EGL_NO_SURFACE) eglDestroySurface(gpu.display, gpu.surface);
        gpu.context = EGL_NO_CONTEXT; gpu.surface = EGL_NO_SURFACE; gpu.shared_with = EGL_NO_CONTEXT; gpu.sharing = false;
        // This process's EGL display is shared with Godot: never eglTerminate it here.
    }
};

// Lends the kept programs to a still's bridge, and takes back what it compiled before it is destroyed.
void lend_programs(Bridge& bridge) {
    auto& p = photo_gpu.programs;
    bridge.warp_clear_prog = p[0]; bridge.warp_scatter_prog = p[1]; bridge.warp_keep_prog = p[2];
    bridge.warp_classify_prog = p[3]; bridge.warp_frame_2d_prog = p[4]; bridge.warp_frame_oes_prog = p[5];
    bridge.stretch_2d_prog = p[6];
}
void keep_programs(Bridge& bridge) {
    photo_gpu.programs = {bridge.warp_clear_prog, bridge.warp_scatter_prog, bridge.warp_keep_prog,
                          bridge.warp_classify_prog, bridge.warp_frame_2d_prog, bridge.warp_frame_oes_prog,
                          bridge.stretch_2d_prog};
    bridge.warp_clear_prog = bridge.warp_scatter_prog = bridge.warp_keep_prog = 0;
    bridge.warp_classify_prog = bridge.warp_frame_2d_prog = bridge.warp_frame_oes_prog = bridge.stretch_2d_prog = 0;
}

// Returns the pair's token for photoPairBegin when it stays on the GPU (0: CPU image only).
jint photo_stereo(const unsigned char* rgba, int w, int h, const float* near, int mw, int mh,
                  const std::array<float, 4>& rect, float strength, unsigned char* output, int turns = 0, float convergence = 0.35f,
                  bool stretch = false, bool keep = true, int basis = 0, bool steady = false) {
    if (w < 1 || h < 1 || w > 4096 || h > 4096 || static_cast<int64_t>(w) * h > 8LL * 1024 * 1024 ||
        mw < 1 || mh < 1 || mw > 518 || mh > 518 || turns < 0 || turns > 3 || !std::isfinite(strength) || strength < 0.f || strength > 2.f)
        throw std::runtime_error("Photo stereo dimensions/strength invalid");
    if (!std::isfinite(convergence) || convergence < 0.f || convergence > 1.f) throw std::runtime_error("Photo stereo convergence invalid");
    for (float v : rect) if (!std::isfinite(v)) throw std::runtime_error("Photo stereo content invalid");
    if (rect[0] < 0 || rect[1] < 0 || rect[2] <= 0 || rect[3] <= 0 || rect[0]+rect[2] > 1.000001f || rect[1]+rect[3] > 1.000001f)
        throw std::runtime_error("Photo stereo content out of bounds");
    // Step timing for the depth log; glFinish puts each step's GPU work in its own lap.
    auto last = std::chrono::steady_clock::now();
    char steps[256] = {}; size_t used = 0;
    const auto lap = [&](const char* name) {
        glFinish();
        const auto now = std::chrono::steady_clock::now();
        const double ms = std::chrono::duration<double, std::milli>(now - last).count(); last = now;
        if (used < sizeof(steps)) used += std::max(0, std::snprintf(steps + used, sizeof(steps) - used, "%s%s=%.1f", used ? " " : "", name, ms));
    };
    std::lock_guard<std::mutex> lock(photo_gpu.context_mutex);
    PhotoCurrent current(photo_gpu);
    lap("egl");
    GLint maximum = 0; glGetIntegerv(GL_MAX_TEXTURE_SIZE, &maximum);
    const int rw = turns % 2 ? h : w, rh = turns % 2 ? w : h;
    const int rmw = turns % 2 ? mh : mw, rmh = turns % 2 ? mw : mh;
    if (std::max(w, rw) * 2 > maximum || std::max(h, rh) > maximum) throw std::runtime_error("Photo stereo exceeds GPU texture limit");
    Bridge bridge(rw, rh, rmw, rmh, 0);
    lend_programs(bridge);
    struct Loan { Bridge& bridge; ~Loan() { keep_programs(bridge); } } loan{bridge}; // before ~Bridge, on any exit
    // Only the still's own colour, mask and warp are allocated; no video slots/decoder/model inputs.
    glGenVertexArrays(1, &bridge.vao); glGenFramebuffers(1, &bridge.fbo);
    const auto rotated_rect = quest::photo_rotated_rect(rect, turns);
    bridge.content_rect = rotated_rect;
    auto& slot = bridge.slots[0]; slot.token = 1; slot.phase = Phase::held;
    image(slot.color, w, h);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, rgba);
    lap("upload");
    // Limit the near map's falls for this strength (render_warp's own half shift, in model columns),
    // so the unchanged hole fill cannot repeat the subject's contour outside it.
    std::vector<float> limited(static_cast<size_t>(mw) * mh);
    for (int y = 0; y < mh; ++y) for (int x = 0; x < mw; ++x) {
        const auto p = quest::photo_rotated_pixel(x, y, mw, mh, turns);
        limited[static_cast<size_t>(p.second) * rmw + p.first] = near[static_cast<size_t>(y) * mw + x];
    }
    // basis: a page of a spread takes the spread's parallax, as any picture on the same screen.
    const float half = quest::photo_half_shift(basis > 0 ? basis : rw, strength);
    const int cx = std::clamp(static_cast<int>(std::lround(rotated_rect[0] * rmw)), 0, rmw - 1);
    const int cy = std::clamp(static_cast<int>(std::lround(rotated_rect[1] * rmh)), 0, rmh - 1);
    const int cw = std::clamp(static_cast<int>(std::lround(rotated_rect[2] * rmw)), 1, rmw - cx);
    const int ch = std::clamp(static_cast<int>(std::lround(rotated_rect[3] * rmh)), 1, rmh - cy);
    const std::vector<float> unlimited(limited);
    quest::photo_limit_gradient(limited.data(), rmw, rmh, cx, cy, cw, ch, half * rotated_rect[2] * rmw / rw);
    std::vector<float> right(limited);
    // Steady edges guide the map with the still's own colour, which is not turned: upright stills only;
    // edge stretching only (with the hole fill the snapped steps follow texture and shred).
    bridge.steady = steady && stretch && turns == 0;
    bridge.upload_alpha(1, limited.data(), right.data());
    if (!stretch) {
        std::vector<unsigned char> bytes(unlimited.size());
        for (size_t i = 0; i < bytes.size(); ++i) bytes[i] = static_cast<unsigned char>(std::lround(std::clamp(unlimited[i], 0.f, 1.f) * 255.f));
        image(bridge.snap_texture, rmw, rmh, GL_R8);
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, rmw, rmh, GL_RED, GL_UNSIGNED_BYTE, bytes.data());
        check_gl("Photo stereo snap map");
    }
    lap("near");
    // Use render_warp directly: the video width cap is a realtime budget, not a still-photo cap.
    if (stretch) bridge.photo_stretch(slot, half, convergence, turns);
    else bridge.render_warp(slot, 0.035f * strength, convergence, half, turns);
    lap("warp");
    glBindBuffer(GL_PIXEL_PACK_BUFFER, 0); glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glReadPixels(0, 0, w * 2, h, GL_RGBA, GL_UNSIGNED_BYTE, output);
    check_gl("Photo stereo readback");
    lap("readback");
    jint token = 0;
    if (keep && photo_gpu.sharing && slot.warp) {
        evict_pairs(kPhotoPairs - 1);
        std::lock_guard<std::mutex> pairs(photo_gpu.pairs_mutex);
        token = ++photo_gpu.next_token;
        if (token <= 0) token = photo_gpu.next_token = 1;
        photo_gpu.pairs[token] = {slot.warp, w * 2, h, photo_gpu.shared_with, nullptr, 0};
        slot.warp = 0; // the registry owns it now; the readback above finished its writes
    }
    __android_log_print(ANDROID_LOG_INFO, "QuestPhotoStereo", "%dx%d %s %s pair=%d passes=[%s]", w, h, stretch ? "stretch" : "fill", steps, token,
                        stretch ? "" : bridge.photo_passes.c_str());
    return token;
}
} // namespace

extern "C" JNIEXPORT jlong JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_photoStereo(JNIEnv* env, jclass, jobject rgba, jint w, jint h,
    jobject near, jint mw, jint mh, jfloatArray content, jfloat strength, jfloat convergence, jint turns, jboolean stretch,
    jint basis, jboolean steady, jobject output, jintArray pair) {
    try {
        // Validate dimensions before calculating buffer sizes or reading arrays.
        if (w < 1 || h < 1 || w > 4096 || h > 4096 || static_cast<int64_t>(w)*h > 8LL*1024*1024 ||
            mw < 1 || mh < 1 || mw > 518 || mh > 518 || !content || env->GetArrayLength(content) != 4 || !pair || env->GetArrayLength(pair) > 1 ||
            basis < 0 || basis > 8192)
            throw std::runtime_error("Photo stereo input invalid");
        const auto* color = static_cast<unsigned char*>(direct_buffer(env, rgba, static_cast<size_t>(w)*h*4, false));
        const auto* depth = float_buffer(env, near, static_cast<size_t>(mw)*mh*4, false);
        auto* result = static_cast<unsigned char*>(direct_buffer(env, output, static_cast<size_t>(w)*h*8, true));
        std::array<float, 4> rect{}; env->GetFloatArrayRegion(content, 0, 4, rect.data());
        if (env->ExceptionCheck()) return 0;
        const auto started = std::chrono::steady_clock::now();
        const bool keep = env->GetArrayLength(pair) == 1;
        const jint token = photo_stereo(color, w, h, depth, mw, mh, rect, strength, result, turns, convergence, stretch == JNI_TRUE, keep, basis,
                                         steady == JNI_TRUE);
        if (keep) env->SetIntArrayRegion(pair, 0, 1, &token);
        return std::max<jlong>(1, std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now()-started).count());
    } catch (const std::exception& e) { error(env, e.what()); return 0; }
}

// Any thread, CPU only: an RGBA8 bitmap turned upright for EXIF orientation 5-8 (the same pixels as
// Godot's ImageInfo.orient) and written as a T3DI v2 file. Godot's in-place rotate_90 follows permutation
// cycles across the whole buffer: 1.47 s for a 22 MP photo on Quest 3. Here 64 output rows are built at a
// time, each reading one 256-byte run per source row, and streamed to the file.
extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_writeUprightRaw(JNIEnv* env, jclass, jobject bitmap, jint orientation, jstring path) {
    AndroidBitmapInfo info{};
    if (orientation < 5 || orientation > 8 || AndroidBitmap_getInfo(env, bitmap, &info) != ANDROID_BITMAP_RESULT_SUCCESS ||
        info.format != ANDROID_BITMAP_FORMAT_RGBA_8888 || info.width < 1 || info.height < 1 || info.width > 8192 || info.height > 8192)
        return JNI_FALSE;
    const char* name = env->GetStringUTFChars(path, nullptr);
    if (!name) return JNI_FALSE;
    const std::string target = name;
    env->ReleaseStringUTFChars(path, name);
    const std::string partial = target + ".part";
    void* pixels = nullptr;
    if (AndroidBitmap_lockPixels(env, bitmap, &pixels) != ANDROID_BITMAP_RESULT_SUCCESS || !pixels) return JNI_FALSE;
    const int w = static_cast<int>(info.width), h = static_cast<int>(info.height);
    const size_t stride = info.stride / 4;
    const auto* in = static_cast<const uint32_t*>(pixels);
    bool ok = false;
    if (FILE* file = std::fopen(partial.c_str(), "wb")) {
        // Header: "T3DI", width, height, version 2 (straight alpha), little-endian. The output is h x w.
        const uint32_t header[] = {0x49443354u, static_cast<uint32_t>(h), static_cast<uint32_t>(w), 2u};
        ok = std::fwrite(header, sizeof(header), 1, file) == 1;
        constexpr int kStrip = 64;
        std::vector<uint32_t> strip(static_cast<size_t>(h) * kStrip);
        const bool rows_forward = orientation == 5 || orientation == 8; // out column x reads source row x
        const bool columns_forward = orientation == 5 || orientation == 6; // out row y reads source column y
        for (int top = 0; ok && top < w; top += kStrip) {
            const int rows = std::min(kStrip, w - top);
            for (int x = 0; x < h; ++x) {
                const uint32_t* source = in + static_cast<size_t>(rows_forward ? x : h - 1 - x) * stride;
                for (int r = 0; r < rows; ++r) {
                    const int y = top + r;
                    strip[static_cast<size_t>(r) * h + x] = source[columns_forward ? y : w - 1 - y];
                }
            }
            ok = std::fwrite(strip.data(), sizeof(uint32_t), static_cast<size_t>(rows) * h, file) == static_cast<size_t>(rows) * h;
        }
        ok = std::fclose(file) == 0 && ok;
    }
    AndroidBitmap_unlockPixels(env, bitmap);
    ok = ok && std::rename(partial.c_str(), target.c_str()) == 0;
    if (!ok) std::remove(partial.c_str());
    return ok ? JNI_TRUE : JNI_FALSE;
}

// Godot's GL thread: the context photo pairs are shared with. Taking effect at the next still.
extern "C" JNIEXPORT void JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_photoShareContext(JNIEnv*, jclass) {
    const EGLContext context = eglGetCurrentContext();
    if (context == EGL_NO_CONTEXT) return;
    godot_display.store(eglGetCurrentDisplay());
    godot_context.store(context);
}

// Godot's GL thread: the GL name of pair [token] for one copy, or 0 when it is gone (evicted, or
// another share group). Every non-zero result is followed by photoPairEnd.
extern "C" JNIEXPORT jint JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_photoPairBegin(JNIEnv*, jclass, jint token) {
    std::lock_guard<std::mutex> lock(photo_gpu.pairs_mutex);
    const auto found = photo_gpu.pairs.find(token);
    if (found == photo_gpu.pairs.end() || found->second.group != eglGetCurrentContext()) return 0;
    auto& pair = found->second;
    // Binding it here makes the worker context's finished writes visible to this one.
    GLint bound = 0; glGetIntegerv(GL_TEXTURE_BINDING_2D, &bound);
    glBindTexture(GL_TEXTURE_2D, pair.texture); glBindTexture(GL_TEXTURE_2D, static_cast<GLuint>(bound));
    ++pair.busy;
    return static_cast<jint>(pair.texture);
}

extern "C" JNIEXPORT void JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_photoPairEnd(JNIEnv*, jclass, jint token) {
    {
        std::lock_guard<std::mutex> lock(photo_gpu.pairs_mutex);
        const auto found = photo_gpu.pairs.find(token);
        if (found == photo_gpu.pairs.end()) return;
        auto& pair = found->second;
        if (pair.used) glDeleteSync(pair.used);
        pair.used = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0); // eviction waits for this copy
        pair.busy = std::max(0, pair.busy - 1);
    }
    glFlush();
}

// Photo viewing closed: free the pairs' GPU memory (the context and programs stay).
extern "C" JNIEXPORT void JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_photoReleasePairs(JNIEnv*, jclass) {
    try {
        std::lock_guard<std::mutex> lock(photo_gpu.context_mutex);
        if (photo_gpu.context == EGL_NO_CONTEXT) return;
        PhotoCurrent current(photo_gpu);
        evict_pairs(0);
    } catch (const std::exception& e) {
        __android_log_print(ANDROID_LOG_WARN, "QuestPhotoStereo", "Releasing pairs failed: %s", e.what());
    }
}

extern "C" JNIEXPORT jlongArray JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_freezePair(JNIEnv* env, jclass, jlong id, jlong token, jboolean warped) {
    try {
        std::lock_guard<std::mutex> guard(registry_mutex);
        auto& b = find(id); auto& slot = b.find(token);
        if (slot.phase != Phase::held || !slot.alpha_valid || !frozen_frames.empty())
            throw std::runtime_error("Freeze requires one complete held display pair and no previous snapshot");
        const bool warp = warped == JNI_TRUE;
        if (warp && !slot.warp) throw std::runtime_error("Frozen stereo warp unavailable");
        const int width = warp ? b.warp_width * 2 : b.width;
        const int height = warp ? b.warp_height : b.height;
        const auto started = std::chrono::steady_clock::now();
        State state;
        auto frozen = std::make_unique<FrozenFrame>();
        image(frozen->color, width, height);
        image(frozen->alpha, b.input_width * 2, b.input_height, GL_R8);
        glBindFramebuffer(GL_FRAMEBUFFER, b.fbo); glBindVertexArray(b.vao); glActiveTexture(GL_TEXTURE0);
        auto copy = [&](GLuint source, GLenum target, GLuint destination, int w, int h, GLuint prog) {
            glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, destination, 0);
            if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE)
                throw std::runtime_error("Freeze framebuffer incomplete");
            glViewport(0, 0, w, h); glUseProgram(prog); glBindTexture(target, source);
            glUniform1i(glGetUniformLocation(prog, "source"), 0);
            if (target == GL_TEXTURE_EXTERNAL_OES)
                glUniform2f(glGetUniformLocation(prog, "uv_scale"), slot.uv_scale[0], slot.uv_scale[1]);
            glDrawArrays(GL_TRIANGLES, 0, 3);
            check_gl("Freeze frame GPU copy");
        };
        if (!warp && slot.decoder_texture) {
            if (!b.freeze_oes) b.freeze_oes = program(freeze_oes_fragment);
            copy(slot.decoder_texture, GL_TEXTURE_EXTERNAL_OES, frozen->color, width, height, b.freeze_oes);
        } else copy(warp ? slot.warp : slot.source(), GL_TEXTURE_2D, frozen->color, width, height, b.copy_2d);
        copy(slot.alpha, GL_TEXTURE_2D, frozen->alpha, b.input_width * 2, b.input_height, b.copy_2d);
        if (slot.portrait_valid && !warp) {
            image(frozen->portrait, b.input_width, b.input_height, GL_R8);
            copy(slot.portrait, GL_TEXTURE_2D, frozen->portrait, b.input_width, b.input_height, b.copy_2d);
        }
        // A seek may flush MediaCodec on a different context/thread as soon as
        // this callback returns. Complete this one transition copy before it.
        glFinish(); check_gl("Freeze frame GPU completion");
        if (sequence == std::numeric_limits<jlong>::max()) throw std::runtime_error("Frozen handle space exhausted");
        const jlong handle = ++sequence;
        const jlong values[] = {handle, frozen->color, frozen->alpha, width, height,
            std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - started).count(), frozen->portrait};
        auto result = env->NewLongArray(7);
        if (!result) return nullptr;
        env->SetLongArrayRegion(result, 0, 7, values);
        if (env->ExceptionCheck()) return nullptr;
        frozen_frames.emplace(handle, std::move(frozen));
        return result;
    } catch (const std::exception& e) { error(env, e.what()); return nullptr; }
}
extern "C" JNIEXPORT void JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_releaseFrozen(JNIEnv*, jclass, jlong id) {
    std::lock_guard<std::mutex> guard(registry_mutex);
    // After the caller detached its wrappers/last draw, GL deletion preserves
    // in-flight GPU uses. A lost context's names must never be deleted in a new one.
    frozen_frames.erase(id);
}

extern "C" JNIEXPORT jlong JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_createLayout(JNIEnv* env, jclass, jint w, jint h, jint iw, jint ih, jint layout) {
    try {
        if (w < 1 || h < 1 || w > 8192 || h > 8192 || static_cast<int64_t>(w)*h > 8192LL*4320 ||
            iw < 1 || ih < 1 || iw > 512 || ih > 512 || layout < 0 || layout > 2 || (layout == 1 && w % 2 != 0) ||
            (layout == 2 && h % 2 != 0))
            throw std::runtime_error("Render bridge dimensions unsupported");
        std::lock_guard<std::mutex> guard(registry_mutex);
        if (registry.size() >= 2 || sequence == std::numeric_limits<jlong>::max()) throw std::runtime_error("Render bridge instance capacity exhausted");
        auto bridge = std::make_unique<Bridge>(w, h, iw, ih, layout); bridge->allocate();
        const auto id = ++sequence; registry.emplace(id, std::move(bridge)); return id;
    } catch (const std::exception& e) { error(env, e.what()); return 0; }
}
extern "C" JNIEXPORT jint JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_oesTexture(JNIEnv* env, jclass, jlong id) {
    try { std::lock_guard<std::mutex> guard(registry_mutex); return find(id).oes; }
    catch (const std::exception& e) { error(env, e.what()); return 0; }
}
extern "C" JNIEXPORT jlong JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_capture(JNIEnv* env, jclass, jlong id, jfloatArray matrix) {
    try {
        if (!matrix || env->GetArrayLength(matrix) != 16) throw std::runtime_error("Render bridge transform invalid");
        std::array<float, 16> transform; env->GetFloatArrayRegion(matrix, 0, 16, transform.data());
        if (env->ExceptionCheck()) return 0;
        for (float value : transform) if (!std::isfinite(value)) throw std::runtime_error("Render bridge transform nonfinite");
        std::lock_guard<std::mutex> guard(registry_mutex);
        if (token_sequence == std::numeric_limits<jlong>::max()) throw std::runtime_error("Render bridge lease space exhausted");
        return find(id).capture(transform.data(), ++token_sequence);
    } catch (const std::exception& e) { error(env, e.what()); return 0; }
}
extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_ready(JNIEnv* env, jclass, jlong id, jlong token) {
    try { std::lock_guard<std::mutex> guard(registry_mutex); auto& bridge = find(id); return bridge.poll(bridge.find(token)) ? JNI_TRUE : JNI_FALSE; }
    catch (const std::exception& e) { error(env, e.what()); return JNI_FALSE; }
}
extern "C" JNIEXPORT jlong JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_captureTexture(JNIEnv* env, jclass, jlong id, jint texture, jboolean inputs) {
    try {
        if (texture <= 0) throw std::runtime_error("Shared MPV texture name invalid");
        std::lock_guard<std::mutex> guard(registry_mutex);
        if (token_sequence == std::numeric_limits<jlong>::max()) throw std::runtime_error("Render bridge lease space exhausted");
        return find(id).capture_texture(static_cast<GLuint>(texture), ++token_sequence, inputs == JNI_TRUE);
    } catch (const std::exception& e) { error(env, e.what()); return 0; }
}
extern "C" JNIEXPORT jlong JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_captureTextureRoi(JNIEnv* env, jclass, jlong id, jint texture,
                                                                        jfloatArray rect, jboolean scout) {
    try {
        if (texture <= 0) throw std::runtime_error("Shared MPV texture name invalid");
        if (!rect || env->GetArrayLength(rect) != 4) throw std::runtime_error("ROI rect must have four values");
        std::array<float, 4> window; env->GetFloatArrayRegion(rect, 0, 4, window.data());
        if (env->ExceptionCheck()) return 0;
        for (float v : window) if (!std::isfinite(v)) throw std::runtime_error("ROI rect nonfinite");
        // Window in eye UV is [-xy/zw, (1-xy)/zw]; it must overlap the eye and zoom at most 8x.
        for (int axis = 0; axis < 2; ++axis) {
            const float scale = window[axis + 2], start = -window[axis] / scale, end = (1.f - window[axis]) / scale;
            if (!(scale > 0.f && scale <= 8.f && end > 0.f && start < 1.f)) throw std::runtime_error("ROI rect outside the eye");
        }
        std::lock_guard<std::mutex> guard(registry_mutex);
        if (token_sequence == std::numeric_limits<jlong>::max()) throw std::runtime_error("Render bridge lease space exhausted");
        return find(id).capture_texture(static_cast<GLuint>(texture), ++token_sequence, true, false, window.data(), scout == JNI_TRUE);
    } catch (const std::exception& e) { error(env, e.what()); return 0; }
}
/** Memory saver: at most [limit] slots in flight (2..7). */
extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_setSlotLimit(JNIEnv* env, jclass, jlong id, jint limit) {
    try {
        std::lock_guard<std::mutex> guard(registry_mutex); auto& bridge = find(id);
        if (limit < 2 || limit > static_cast<jint>(bridge.slots.size())) return JNI_FALSE;
        bridge.slot_limit = static_cast<size_t>(limit);
        return JNI_TRUE;
    } catch (const std::exception& e) { error(env, e.what()); return JNI_FALSE; }
}
extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_enableZeroCopy(JNIEnv* env, jclass, jlong id) {
    try {
        std::lock_guard<std::mutex> guard(registry_mutex); auto& bridge = find(id);
        if (!egl_image().available()) return JNI_FALSE;
        bridge.zero_copy = true;
        return JNI_TRUE;
    } catch (const std::exception& e) { error(env, e.what()); return JNI_FALSE; }
}
extern "C" JNIEXPORT jlong JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_captureBufferRoi(JNIEnv* env, jclass, jlong id, jlong buffer,
    jint buffer_width, jint buffer_height, jfloatArray rect, jboolean scout) {
    try {
        if (!rect || env->GetArrayLength(rect) != 4) throw std::runtime_error("Decoder capture window invalid");
        std::array<float, 4> window; env->GetFloatArrayRegion(rect, 0, 4, window.data());
        if (env->ExceptionCheck()) return 0;
        for (float value : window) if (!std::isfinite(value)) throw std::runtime_error("Decoder capture window nonfinite");
        std::lock_guard<std::mutex> guard(registry_mutex);
        if (token_sequence == std::numeric_limits<jlong>::max()) throw std::runtime_error("Render bridge lease space exhausted");
        return find(id).capture_buffer(reinterpret_cast<AHardwareBuffer*>(static_cast<uintptr_t>(buffer)), buffer_width, buffer_height,
                                       ++token_sequence, window.data(), scout == JNI_TRUE);
    } catch (const std::exception& e) { error(env, e.what()); return 0; }
}
// EGLImage of a held decoder-buffer slot (0 for copied/borrowed RGBA colors).
extern "C" JNIEXPORT jlong JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_colorImage(JNIEnv* env, jclass, jlong id, jlong token) {
    try {
        std::lock_guard<std::mutex> guard(registry_mutex); auto& slot = find(id).find(token);
        if (slot.phase != Phase::held) throw std::runtime_error("Render bridge color not ready");
        return static_cast<jlong>(reinterpret_cast<uintptr_t>(slot.decoder_image));
    } catch (const std::exception& e) { error(env, e.what()); return 0; }
}
// Borrowed color: captures keep the producer texture (no full-resolution copy). The caller must
// hold the producer lease until retired() reports the slot free.
extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_enableBorrowedColor(JNIEnv* env, jclass, jlong id) {
    try {
        std::lock_guard<std::mutex> guard(registry_mutex); find(id).borrow = true;
        return JNI_TRUE;
    } catch (const std::exception& e) { error(env, e.what()); return JNI_FALSE; }
}
extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_enableEdgeFill(JNIEnv* env, jclass, jlong id) {
    try {
        std::lock_guard<std::mutex> guard(registry_mutex); find(id).edge_fill = true;
        return JNI_TRUE;
    } catch (const std::exception& e) { error(env, e.what()); return JNI_FALSE; }
}
// {input L, input R, alpha L, alpha R} AHardwareBuffer handles of a held slot (or its scout set).
extern "C" JNIEXPORT jlongArray JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_zeroCopyBuffers(JNIEnv* env, jclass, jlong id, jlong token, jboolean scout) {
    try {
        std::array<jlong, 4> handles{};
        {
            std::lock_guard<std::mutex> guard(registry_mutex); auto& bridge = find(id); auto& slot = bridge.find(token);
            bridge.current();
            if (slot.phase != Phase::held || !bridge.zero_copy) throw std::runtime_error("Zero-copy buffers need a held color");
            if (scout && !slot.scout_staged) throw std::runtime_error("No ROI scout input was staged for this color");
            if (scout) bridge.ensure_shared(bridge.zc_scout_out, kOutputUsage);
            const auto& input = scout ? slot.zc_scout_in : slot.zc_in;
            const auto& output = scout ? bridge.zc_scout_out : slot.zc_out;
            for (int eye = 0; eye < 2; ++eye)
                if (!input[eye].buffer || !output[eye].buffer) throw std::runtime_error("Zero-copy buffers missing");
            // The inference worker may still use these after this bridge closes (session revision):
            // each handle carries its own reference, released with releaseBuffers().
            for (int eye = 0; eye < 2; ++eye) {
                AHardwareBuffer_acquire(input[eye].buffer); AHardwareBuffer_acquire(output[eye].buffer);
                handles[eye] = static_cast<jlong>(reinterpret_cast<uintptr_t>(input[eye].buffer));
                handles[eye + 2] = static_cast<jlong>(reinterpret_cast<uintptr_t>(output[eye].buffer));
            }
        }
        auto result = env->NewLongArray(4);
        if (result) env->SetLongArrayRegion(result, 0, 4, handles.data());
        return result;
    } catch (const std::exception& e) { error(env, e.what()); return nullptr; }
}
// A Java HardwareBuffer's native buffer (no reference added: the Java object keeps it alive until the
// capture's EGLImage holds its own). Frames fanned out from the decoder's layer surface (Alpha plan B).
extern "C" JNIEXPORT jlong JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_hardwareBufferPointer(JNIEnv* env, jclass, jobject buffer) {
    if (!buffer) return 0;
    return static_cast<jlong>(reinterpret_cast<uintptr_t>(AHardwareBuffer_fromHardwareBuffer(env, buffer)));
}
// Drops the references zeroCopyBuffers() handed out. Any thread; the bridge may be gone.
extern "C" JNIEXPORT void JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_releaseBuffers(JNIEnv* env, jclass, jlongArray buffers) {
    if (!buffers) return;
    const auto count = env->GetArrayLength(buffers);
    std::vector<jlong> values(static_cast<size_t>(count));
    env->GetLongArrayRegion(buffers, 0, count, values.data());
    for (jlong value : values)
        if (value) AHardwareBuffer_release(reinterpret_cast<AHardwareBuffer*>(static_cast<uintptr_t>(value)));
}
extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_commitZeroCopyAlpha(JNIEnv* env, jclass, jlong id, jlong token) {
    try { std::lock_guard<std::mutex> guard(registry_mutex); find(id).commit_zero_copy_alpha(token); return JNI_TRUE; }
    catch (const std::exception& e) { error(env, e.what()); return JNI_FALSE; }
}
extern "C" JNIEXPORT jfloatArray JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_fullInputRect(JNIEnv* env, jclass, jlong id) {
    try {
        std::array<float, 4> rect;
        { std::lock_guard<std::mutex> guard(registry_mutex); rect = find(id).content_rect; }
        auto result = env->NewFloatArray(4);
        if (result) env->SetFloatArrayRegion(result, 0, 4, rect.data());
        return result;
    } catch (const std::exception& e) { error(env, e.what()); return nullptr; }
}
extern "C" JNIEXPORT jint JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_texture(JNIEnv* env, jclass, jlong id, jlong token) {
    try {
        std::lock_guard<std::mutex> guard(registry_mutex); auto& slot = find(id).find(token);
        if (slot.phase != Phase::held) throw std::runtime_error("Render bridge color not ready");
        return slot.decoder_texture ? slot.decoder_texture : slot.source();
    } catch (const std::exception& e) { error(env, e.what()); return 0; }
}
extern "C" JNIEXPORT jlong JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_captureOpaqueTexture(JNIEnv* env, jclass, jlong id, jint texture) {
    try {
        if (texture <= 0) throw std::runtime_error("Shared MPV texture name invalid");
        std::lock_guard<std::mutex> guard(registry_mutex);
        if (token_sequence == std::numeric_limits<jlong>::max()) throw std::runtime_error("Render bridge lease space exhausted");
        return find(id).capture_texture(static_cast<GLuint>(texture), ++token_sequence, false, true);
    } catch (const std::exception& e) { error(env, e.what()); return 0; }
}
extern "C" JNIEXPORT jlong JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_captureOpaqueBuffer(JNIEnv* env, jclass, jlong id, jlong buffer,
    jint buffer_width, jint buffer_height) {
    try {
        std::lock_guard<std::mutex> guard(registry_mutex);
        if (token_sequence == std::numeric_limits<jlong>::max()) throw std::runtime_error("Render bridge lease space exhausted");
        return find(id).capture_buffer(reinterpret_cast<AHardwareBuffer*>(static_cast<uintptr_t>(buffer)), buffer_width, buffer_height,
                                       ++token_sequence, nullptr, false, true);
    } catch (const std::exception& e) { error(env, e.what()); return 0; }
}
extern "C" JNIEXPORT jdouble JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_backgroundGpuTiming(JNIEnv*, jclass, jint action) {
    return background_frame_timer.update(action);
}
extern "C" JNIEXPORT jstring JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_stats(JNIEnv* env, jclass, jlong id) {
    try {
        std::lock_guard<std::mutex> guard(registry_mutex); auto& b = find(id);
        std::array<int, 4> phases{};
        for (const auto& s : b.slots) phases[static_cast<size_t>(s.phase)]++;
        auto json = "{\"copies\":" + std::to_string(b.copies) + ",\"opaque_copies\":" + std::to_string(b.opaque_copies) +
            ",\"opaque_initial_uploads\":" + std::to_string(b.opaque_uploads) + ",\"regular_alpha_uploads\":" + std::to_string(b.alpha_uploads) +
            ",\"input_stages\":" + std::to_string(b.input_stages) + ",\"copy_pending_polls\":" + std::to_string(b.copy_pending_polls) +
            ",\"retire_pending_polls\":" + std::to_string(b.retire_pending_polls) + ",\"slot_exhaustions\":" + std::to_string(b.slot_exhaustions) + ",\"borrowed_captures\":" + std::to_string(b.borrows) + ",\"decoder_captures\":" + std::to_string(b.decoder_captures) +
            ",\"zero_copy\":" + (b.zero_copy ? "true" : "false") + ",\"zero_copy_commits\":" + std::to_string(b.zero_copy_commits) +
            ",\"warp_frames\":" + std::to_string(b.warp_frames) + ",\"warp_maps\":" + std::to_string(b.warp_maps) +
            ",\"warp_half_shift_px\":" + std::to_string(b.map_half) +
            ",\"warp_failed\":" + (b.warp_failed ? "true" : "false") +
            ",\"warp_map_gpu_ms\":" + std::to_string(b.map_timer.ms) + ",\"warp_frame_gpu_ms\":" + std::to_string(b.frame_timer.ms) +
            ",\"portrait_frames\":" + std::to_string(b.portrait_frames) + ",\"portrait_gpu_ms\":" + std::to_string(b.portrait_timer.ms) +
            ",\"portrait_gpu_samples\":" + std::to_string(b.portrait_timer.samples) +
            ",\"free_slots\":" + std::to_string(phases[0]) + ",\"copying_slots\":" + std::to_string(phases[1]) +
            ",\"held_slots\":" + std::to_string(phases[2]) + ",\"retiring_slots\":" + std::to_string(phases[3]) + "}";
        return env->NewStringUTF(json.c_str());
    } catch (const std::exception& e) { error(env, e.what()); return nullptr; }
}
static jboolean read_inputs(JNIEnv* env, jlong id, jlong token, jobject left, jobject right, bool scout, bool mono = false) {
    try {
        std::lock_guard<std::mutex> guard(registry_mutex); auto& bridge = find(id); auto& slot = bridge.find(token);
        if (slot.phase != Phase::held) return JNI_FALSE;
        if (mono && bridge.layout != 0) throw std::runtime_error("Mono model input requires mono color");
        if (scout && !slot.scout_staged) throw std::runtime_error("No ROI scout input was staged for this color");
        const auto& pbos = scout ? slot.scout_pbo : slot.pbo;
        const size_t plane = static_cast<size_t>(bridge.input_width)*bridge.input_height;
        const size_t output_bytes = plane*3*sizeof(float);
        std::array<float*, 2> outputs{{float_buffer(env, left, output_bytes), mono ? nullptr : float_buffer(env, right, output_bytes)}};
        const auto a = reinterpret_cast<uintptr_t>(outputs[0]), b = reinterpret_cast<uintptr_t>(outputs[1]);
        if (!mono && ((a <= b && b-a < output_bytes) || (b < a && a-b < output_bytes))) throw std::runtime_error("Render bridge CHW outputs overlap");
        State state;
        for (int eye = 0; eye < (bridge.layout == 0 ? 1 : 2); ++eye) {
            glBindBuffer(GL_PIXEL_PACK_BUFFER, pbos[eye]);
            const auto* rgba = static_cast<const unsigned char*>(glMapBufferRange(GL_PIXEL_PACK_BUFFER, 0, plane*4, GL_MAP_READ_BIT));
            if (!rgba) throw std::runtime_error("Render bridge PBO map failed");
            for (int channel = 0; channel < 3; ++channel) for (size_t i = 0; i < plane; ++i) outputs[eye][channel*plane+i] = rgba[i*4+channel]/255.f;
            if (!glUnmapBuffer(GL_PIXEL_PACK_BUFFER)) throw std::runtime_error("Render bridge PBO storage corrupted");
        }
        if (bridge.layout == 0 && !mono) std::memcpy(outputs[1], outputs[0], output_bytes);
        return JNI_TRUE;
    } catch (const std::exception& e) { error(env, e.what()); return JNI_FALSE; }
}
extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_readInputs(JNIEnv* env, jclass, jlong id, jlong token, jobject left, jobject right) {
    return read_inputs(env, id, token, left, right, false);
}
extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_readMonoInput(JNIEnv* env, jclass, jlong id, jlong token, jobject rgb) {
    return read_inputs(env, id, token, rgb, nullptr, false, true);
}
extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_readScoutInputs(JNIEnv* env, jclass, jlong id, jlong token, jobject left, jobject right) {
    return read_inputs(env, id, token, left, right, true);
}
extern "C" JNIEXPORT void JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_retire(JNIEnv* env, jclass, jlong id, jlong token) {
    try {
        std::lock_guard<std::mutex> guard(registry_mutex); auto& slot = find(id).find(token);
        if (slot.phase == Phase::retiring) return;
        if (slot.fence) glDeleteSync(slot.fence);
        if (slot.alpha_fence) { glDeleteSync(slot.alpha_fence); slot.alpha_fence = nullptr; }
        slot.alpha_valid = false;
        slot.fence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
        if (!slot.fence) throw std::runtime_error("Render bridge release fence unavailable");
        slot.phase = Phase::retiring; glFlush();
    } catch (const std::exception& e) { error(env, e.what()); }
}
extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_retired(JNIEnv* env, jclass, jlong id, jlong token) {
    try {
        std::lock_guard<std::mutex> guard(registry_mutex); auto& bridge = find(id);
        for (auto& slot : bridge.slots) if (token > 0 && slot.token == token) {
            if (slot.phase == Phase::retiring) bridge.poll(slot);
            return slot.phase == Phase::free ? JNI_TRUE : JNI_FALSE;
        }
        throw std::runtime_error("Render bridge retirement token unknown");
    } catch (const std::exception& e) { error(env, e.what()); return JNI_FALSE; }
}
extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_uploadAlpha(JNIEnv* env, jclass, jlong id, jlong token, jobject left, jobject right) {
    try {
        std::lock_guard<std::mutex> guard(registry_mutex); auto& bridge = find(id);
        const size_t bytes = static_cast<size_t>(bridge.input_width)*bridge.input_height*sizeof(float);
        const auto* l = float_buffer(env, left, bytes, false); const auto* r = float_buffer(env, right, bytes, false);
        bridge.upload_alpha(token, l, r); return JNI_TRUE;
    } catch (const std::exception& e) { error(env, e.what()); return JNI_FALSE; }
}
extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_limitNear(JNIEnv* env, jclass, jlong id, jlong token, jfloat shift) {
    try {
        if (!std::isfinite(shift) || shift < 0.f || shift > 0.2f) throw std::runtime_error("Near limit shift invalid");
        std::lock_guard<std::mutex> guard(registry_mutex); find(id).limit_near(token, shift); return JNI_TRUE;
    } catch (const std::exception& e) { error(env, e.what()); return JNI_FALSE; }
}
extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_steadyEdges(JNIEnv* env, jclass, jlong id, jboolean enabled) {
    try {
        std::lock_guard<std::mutex> guard(registry_mutex); find(id).steady = enabled == JNI_TRUE; return JNI_TRUE;
    } catch (const std::exception& e) { error(env, e.what()); return JNI_FALSE; }
}
extern "C" JNIEXPORT jint JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_warp(JNIEnv* env, jclass, jlong id, jlong token, jfloat shift, jfloat convergence) {
    try {
        if (!std::isfinite(shift) || !std::isfinite(convergence) || shift < 0.f || shift > 0.2f || convergence < 0.f || convergence > 1.f)
            throw std::runtime_error("2D->3D warp parameters invalid");
        std::lock_guard<std::mutex> guard(registry_mutex); return static_cast<jint>(find(id).warp(token, shift, convergence));
    } catch (const std::exception& e) { error(env, e.what()); return 0; }
}
extern "C" JNIEXPORT jint JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_stretch(JNIEnv* env, jclass, jlong id, jlong token, jfloat shift, jfloat convergence) {
    try {
        if (!std::isfinite(shift) || !std::isfinite(convergence) || shift < 0.f || shift > 0.2f || convergence < 0.f || convergence > 1.f)
            throw std::runtime_error("2D->3D stretch parameters invalid");
        std::lock_guard<std::mutex> guard(registry_mutex); return static_cast<jint>(find(id).stretch(token, shift, convergence));
    } catch (const std::exception& e) { error(env, e.what()); return 0; }
}
extern "C" JNIEXPORT jintArray JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_warpSize(JNIEnv* env, jclass, jlong id) {
    try {
        std::lock_guard<std::mutex> guard(registry_mutex); auto& bridge = find(id);
        const jint values[] = {bridge.warp_width * 2, bridge.warp_height};
        auto result = env->NewIntArray(2);
        if (result) env->SetIntArrayRegion(result, 0, 2, values);
        return result;
    } catch (const std::exception& e) { error(env, e.what()); return nullptr; }
}
extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_alphaReady(JNIEnv* env, jclass, jlong id, jlong token) {
    try { std::lock_guard<std::mutex> guard(registry_mutex); auto& bridge = find(id); return bridge.alpha_ready(bridge.find(token)) ? JNI_TRUE : JNI_FALSE; }
    catch (const std::exception& e) { error(env, e.what()); return JNI_FALSE; }
}
extern "C" JNIEXPORT jint JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_warpAlpha(JNIEnv* env, jclass, jlong id, jlong token,
                                                               jfloat shift, jfloat convergence, jint matte, jfloatArray content) {
    try {
        if (!std::isfinite(shift) || !std::isfinite(convergence) || shift < 0.f || shift > 0.2f || convergence < 0.f || convergence > 1.f || matte <= 0 ||
            !content || env->GetArrayLength(content) != 4) throw std::runtime_error("Browser matte warp parameters invalid");
        std::array<float, 4> rect{}; env->GetFloatArrayRegion(content, 0, 4, rect.data());
        if (env->ExceptionCheck()) return 0;
        for (auto value : rect) if (!std::isfinite(value)) throw std::runtime_error("Browser matte rectangle nonfinite");
        if (rect[0] < 0 || rect[1] < 0 || rect[2] <= 0 || rect[3] <= 0 || rect[0]+rect[2] > 1.00001f || rect[1]+rect[3] > 1.00001f)
            throw std::runtime_error("Browser matte rectangle invalid");
        std::lock_guard<std::mutex> guard(registry_mutex);
        return static_cast<jint>(find(id).warp(token, shift, convergence, static_cast<GLuint>(matte), rect.data()));
    } catch (const std::exception& e) { error(env, e.what()); return 0; }
}
extern "C" JNIEXPORT jint JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_preparePortrait(JNIEnv* env, jclass, jlong id, jlong token, jfloat lod_bias, jobject residual) {
    try {
        if (!std::isfinite(lod_bias) || lod_bias < -4.f || lod_bias > 4.f) throw std::runtime_error("Portrait mip scale invalid");
        const auto* bytes = residual ? static_cast<unsigned char*>(direct_buffer(env, residual, 64*64, false)) : nullptr;
        std::lock_guard<std::mutex> guard(registry_mutex); return static_cast<jint>(find(id).prepare_portrait(token, lod_bias, bytes));
    }
    catch (const std::exception& e) { error(env, e.what()); return 0; }
}
extern "C" JNIEXPORT jint JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_alphaTexture(JNIEnv* env, jclass, jlong id, jlong token) {
    try {
        std::lock_guard<std::mutex> guard(registry_mutex); auto& slot = find(id).find(token);
        if (slot.phase != Phase::held || !slot.alpha_valid) throw std::runtime_error("Alpha texture not ready");
        return slot.alpha;
    } catch (const std::exception& e) { error(env, e.what()); return 0; }
}
extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_readAlpha(JNIEnv* env, jclass, jlong id, jlong token, jobject output) {
    try {
        std::lock_guard<std::mutex> guard(registry_mutex); auto& bridge = find(id); auto& slot = bridge.find(token);
        if (slot.phase != Phase::held || !slot.alpha_valid) return JNI_FALSE;
        const size_t pixels = static_cast<size_t>(bridge.input_width)*bridge.input_height*2;
        auto* destination = static_cast<unsigned char*>(direct_buffer(env, output, pixels, true));
        State state; bridge.target(slot.alpha, bridge.input_width*2, bridge.input_height);
        glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
        // ES3 guarantees RGBA/UNSIGNED_BYTE readback for normalized attachments.
        std::vector<unsigned char> rgba(pixels*4);
        glReadPixels(0, 0, bridge.input_width*2, bridge.input_height, GL_RGBA, GL_UNSIGNED_BYTE, rgba.data());
        if (glGetError() != GL_NO_ERROR) throw std::runtime_error("Alpha readback GL error");
        for (size_t i = 0; i < pixels; ++i) destination[i] = rgba[i*4];
        return JNI_TRUE;
    } catch (const std::exception& e) { error(env, e.what()); return JNI_FALSE; }
}
extern "C" JNIEXPORT void JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_stagePortraitMask(JNIEnv* env, jclass, jlong id, jlong token) {
    try { std::lock_guard<std::mutex> guard(registry_mutex); find(id).stage_portrait_mask(token); }
    catch (const std::exception& e) { error(env, e.what()); }
}
extern "C" JNIEXPORT void JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_readPortraitMask(JNIEnv* env, jclass, jlong id, jlong token, jobject output) {
    try {
        std::lock_guard<std::mutex> guard(registry_mutex);
        find(id).read_portrait_mask(token, static_cast<unsigned char*>(direct_buffer(env, output, 64*64, true)));
    } catch (const std::exception& e) { error(env, e.what()); }
}
extern "C" JNIEXPORT void JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_stagePortraitInput(JNIEnv* env, jclass, jlong id, jlong token,
                                                                        jfloatArray rect, jint width, jint height) {
    try {
        if (width < 16 || height < 16 || width > 1024 || height > 1024 || !rect || env->GetArrayLength(rect) != 4)
            throw std::runtime_error("Portrait depth crop dimensions invalid");
        std::array<float, 4> window{}; env->GetFloatArrayRegion(rect, 0, 4, window.data());
        if (env->ExceptionCheck()) return;
        for (float value : window) if (!std::isfinite(value)) throw std::runtime_error("Portrait crop nonfinite");
        if (window[2] <= 0 || window[3] <= 0) throw std::runtime_error("Portrait crop scale invalid");
        std::lock_guard<std::mutex> guard(registry_mutex); find(id).stage_portrait_input(token, window.data(), width, height);
    } catch (const std::exception& e) { error(env, e.what()); }
}
extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_readPortraitInput(JNIEnv* env, jclass, jlong id, jobject output) {
    try {
        std::lock_guard<std::mutex> guard(registry_mutex); auto& bridge = find(id);
        auto* rgb = static_cast<float*>(direct_buffer(env, output,
            static_cast<size_t>(bridge.portrait_input_width)*bridge.portrait_input_height*3*sizeof(float), true));
        return bridge.read_portrait_input(rgb) ? JNI_TRUE : JNI_FALSE;
    } catch (const std::exception& e) { error(env, e.what()); return JNI_FALSE; }
}
extern "C" JNIEXPORT void JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_stagePortraitShot(JNIEnv* env, jclass, jlong id, jlong token) {
    try { std::lock_guard<std::mutex> guard(registry_mutex); find(id).stage_shot(token); }
    catch (const std::exception& e) { error(env, e.what()); }
}
extern "C" JNIEXPORT void JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_restagePortraitFull(JNIEnv* env, jclass, jlong id, jlong token) {
    try {
        std::lock_guard<std::mutex> guard(registry_mutex); auto& bridge = find(id); bridge.current();
        auto& slot = bridge.find(token);
        if (slot.phase != Phase::held || slot.alpha_fence || slot.alpha_valid)
            throw std::runtime_error("Portrait restaging requires a held colour without Alpha");
        State state; slot.scout_staged = false;
        bridge.stage(slot, token, true, bridge.content_rect.data());
    } catch (const std::exception& e) { error(env, e.what()); }
}
extern "C" JNIEXPORT void JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_readPortraitShot(JNIEnv* env, jclass, jlong id, jlong token, jobject output) {
    try {
        std::lock_guard<std::mutex> guard(registry_mutex);
        find(id).read_shot(token, static_cast<unsigned char*>(direct_buffer(env, output, 48*32*4, true)));
    } catch (const std::exception& e) { error(env, e.what()); }
}
extern "C" JNIEXPORT void JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_close(JNIEnv*, jclass, jlong id) {
    std::lock_guard<std::mutex> guard(registry_mutex); registry.erase(id);
}
extern "C" JNIEXPORT void JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_abandon(JNIEnv*, jclass, jlong id) {
    std::lock_guard<std::mutex> guard(registry_mutex);
    const auto it = registry.find(id);
    if (it != registry.end()) { it->second->abandoned = true; registry.erase(it); }
}

extern "C" JNIEXPORT void JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_textRegions(JNIEnv* env,jclass,jlong id,jlong token,jfloatArray regions,jfloatArray weights) {
    try {
        if(!regions||env->GetArrayLength(regions)>32||env->GetArrayLength(regions)%4)throw std::runtime_error("Text regions invalid");
        if(!weights||env->GetArrayLength(weights)!=env->GetArrayLength(regions)/4)throw std::runtime_error("Text weights invalid");
        std::vector<float> opacity(static_cast<size_t>(env->GetArrayLength(weights)));
        if(!opacity.empty())env->GetFloatArrayRegion(weights,0,static_cast<jsize>(opacity.size()),opacity.data());
        if(env->ExceptionCheck())return;
        for(float value:opacity)if(!std::isfinite(value)||value<0||value>1)throw std::runtime_error("Text opacity invalid");
        std::vector<float> data(static_cast<size_t>(env->GetArrayLength(regions)));
        if(!data.empty())env->GetFloatArrayRegion(regions,0,static_cast<jsize>(data.size()),data.data());
        if(env->ExceptionCheck())return;
        for(size_t i=0;i<data.size();i+=4) {
            for(size_t j=0;j<4;++j)if(!std::isfinite(data[i+j])||data[i+j]<0||data[i+j]>1)throw std::runtime_error("Text region range");
            if(data[i+2]<=data[i]||data[i+3]<=data[i+1])throw std::runtime_error("Text region size");
        }
        std::lock_guard<std::mutex> guard(registry_mutex);auto& b=find(id);b.current();auto& slot=b.find(token);
        if(slot.phase!=Phase::held)throw std::runtime_error("Text regions require a held colour");
        slot.text_regions=std::move(data);slot.text_weights=std::move(opacity);
    }catch(const std::exception& e){error(env,e.what());}
}
extern "C" JNIEXPORT void JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_releaseTextInput(JNIEnv* env,jclass,jlong id) {
    try{std::lock_guard<std::mutex> guard(registry_mutex);find(id).release_text_input();}
    catch(const std::exception& e){error(env,e.what());}
}
