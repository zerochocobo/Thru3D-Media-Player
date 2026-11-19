// Alpha plan B, GPU copy prototype: the decoder writes into an ImageReader whose buffers are reused, and
// each frame is drawn into the compositor layer's surface on a copy thread with its own EGL context. Both
// buffer sets stay fixed (the ImageWriter hand-off made the runtime keep a new buffer per frame).
#include <jni.h>
#include <android/hardware_buffer.h>
#include <android/hardware_buffer_jni.h>
#include <android/log.h>
#include <android/native_window.h>
#include <android/native_window_jni.h>
#define EGL_EGLEXT_PROTOTYPES
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>
#include <list>
#include <string>
#include <vector>
#include "picture_glsl.h"

namespace {

void log(int priority, const std::string& text) { __android_log_write(priority, "QuestLayerCopy", text.c_str()); }

struct Api {
    PFNEGLGETNATIVECLIENTBUFFERANDROIDPROC client = nullptr;
    PFNEGLCREATEIMAGEKHRPROC create = nullptr;
    PFNEGLDESTROYIMAGEKHRPROC destroy = nullptr;
    PFNGLEGLIMAGETARGETTEXTURE2DOESPROC target = nullptr;
    Api() {
        client = reinterpret_cast<PFNEGLGETNATIVECLIENTBUFFERANDROIDPROC>(eglGetProcAddress("eglGetNativeClientBufferANDROID"));
        create = reinterpret_cast<PFNEGLCREATEIMAGEKHRPROC>(eglGetProcAddress("eglCreateImageKHR"));
        destroy = reinterpret_cast<PFNEGLDESTROYIMAGEKHRPROC>(eglGetProcAddress("eglDestroyImageKHR"));
        target = reinterpret_cast<PFNGLEGLIMAGETARGETTEXTURE2DOESPROC>(eglGetProcAddress("glEGLImageTargetTexture2DOES"));
    }
    bool ready() const { return client && create && destroy && target; }
};
const Api& api() { static const Api value; return value; }

// One wrapped decoder buffer: the reader cycles a few, so each is wrapped once.
struct Wrapped { AHardwareBuffer* buffer; EGLImageKHR image; GLuint texture; };
std::list<Wrapped> cache; // copy thread only, newest first
constexpr size_t kCacheLimit = 16;
GLuint program = 0;
GLint scale_location = -1, flip_location = -1;
// Picture quality mode: the copy with contrast-adaptive sharpening where the head looks and the player's
// colour grade, so neither takes playback off the compositor layer.
GLuint sharp_program = 0;
GLint sharp_scale = -1, sharp_flip = -1, sharp_texel = -1, sharp_amount = -1, sharp_window = -1, sharp_eyes = -1, sharp_tint = -1;
GLint sharp_rect = -1, sharp_boost = -1;
// The plain copy over one rectangle of the picture: what lies outside the sharpening window.
GLuint part_program = 0;
GLint part_scale = -1, part_flip = -1, part_rect = -1;
struct Box { float u0, v0, u1, v1; };
// The colour grade's uniforms in one program (color_grade.gdshaderinc holds the same arithmetic).
struct Grade { GLint graded = -1, curved = -1, gain = -1, curve = -1, lift = -1, contrast = -1, saturation = -1; };
Grade part_grade, sharp_grade, finish_grade;
// Super resolution (FSR 1): sources under the display's density are enlarged with EASU into a texture
// of the output's size, which the finishing program sharpens (RCAS) and grades onto the surface. Like
// the sharpening it covers the window the head faces; around it the plain program's bilinear enlarges.
GLuint easu_program = 0, finish_program = 0;
GLint easu_rect = -1, easu_source = -1, easu_buffer = -1, easu_window = -1, easu_eyes = -1;
GLint finish_rect = -1, finish_flip = -1, finish_scale = -1, finish_texel = -1, finish_amount = -1, finish_window = -1,
    finish_eyes = -1, finish_tint = -1, finish_boost = -1;
GLuint upscaled = 0, upscaled_fbo = 0;
int upscaled_width = 0, upscaled_height = 0;
// Denoising comes first, into a texture of the source's size that EASU or the finishing program reads
// in place of the decoder's frame.
GLuint denoise_program = 0, easu_texture_program = 0;
GLuint denoised = 0, denoised_fbo = 0;
int denoised_width = 0, denoised_height = 0;
// GPU time of one copy (GL_EXT_disjoint_timer_query), read a frame or more later without waiting.
struct Timer {
    typedef void (*Result)(GLuint, GLenum, GLuint64*);
    Result result = nullptr; GLuint query = 0; bool pending = false, checked = false; double ms = 0.0;
};
Timer timer;
constexpr GLenum kTimeElapsed = 0x88BF; // GL_TIME_ELAPSED_EXT

void drop(Wrapped& entry) {
    if (entry.texture) glDeleteTextures(1, &entry.texture);
    if (entry.image != EGL_NO_IMAGE_KHR) api().destroy(eglGetCurrentDisplay(), entry.image);
    AHardwareBuffer_release(entry.buffer);
}

GLuint compile(GLenum type, const char* source) {
    const GLuint shader = glCreateShader(type);
    glShaderSource(shader, 1, &source, nullptr); glCompileShader(shader);
    GLint ok = 0; glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char text[512] = {}; glGetShaderInfoLog(shader, sizeof(text) - 1, nullptr, text);
        log(ANDROID_LOG_WARN, std::string("copy shader: ") + text);
        glDeleteShader(shader); return 0;
    }
    return shader;
}

bool ensure_program() {
    if (program) return true;
    static const char* vertex = "#version 300 es\n"
        "uniform bool flip; out vec2 uv;\n"
        "void main() { vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));\n"
        "  uv = vec2(p.x, flip ? 1.0 - p.y : p.y); gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0); }\n";
    // The driver converts the decoder's YUV (8 or 10 bit) to RGB when sampling the external image.
    // highp: uv x 8192 pixels in half floats stepped every 4 pixels across the right half of a
    // side-by-side frame (the right eye's fine detail broke up while the left eye stayed sharp).
    static const char* fragment = "#version 300 es\n"
        "#extension GL_OES_EGL_image_external_essl3 : require\n"
        "precision highp float;\n"
        "uniform samplerExternalOES frame; uniform vec2 scale; in vec2 uv; out vec4 result;\n"
        "void main() { result = vec4(texture(frame, uv * scale).rgb, 1.0); }\n";
    const GLuint vs = compile(GL_VERTEX_SHADER, vertex), fs = compile(GL_FRAGMENT_SHADER, fragment);
    if (!vs || !fs) { if (vs) glDeleteShader(vs); if (fs) glDeleteShader(fs); return false; }
    program = glCreateProgram();
    glAttachShader(program, vs); glAttachShader(program, fs); glLinkProgram(program);
    glDeleteShader(vs); glDeleteShader(fs);
    GLint ok = 0; glGetProgramiv(program, GL_LINK_STATUS, &ok);
    if (!ok) { log(ANDROID_LOG_WARN, "copy program does not link"); glDeleteProgram(program); program = 0; return false; }
    scale_location = glGetUniformLocation(program, "scale");
    flip_location = glGetUniformLocation(program, "flip");
    glUseProgram(program);
    glUniform1i(glGetUniformLocation(program, "frame"), 0);
    return true;
}

GLuint link(const char* vertex, const char* fragment);

Grade grade_locations(GLuint id) {
    Grade at;
    at.graded = glGetUniformLocation(id, "graded"); at.curved = glGetUniformLocation(id, "curved");
    at.gain = glGetUniformLocation(id, "gain"); at.curve = glGetUniformLocation(id, "curve");
    at.lift = glGetUniformLocation(id, "lift"); at.contrast = glGetUniformLocation(id, "contrast");
    at.saturation = glGetUniformLocation(id, "saturation");
    return at;
}

/** values: gain, gamma and offset per channel, contrast, saturation (11), or null for no grade. The
 * gamma step is left out while every exponent is 1. */
void set_grade(const Grade& at, const jfloat* values) {
    glUniform1i(at.graded, values ? 1 : 0);
    if (!values) return;
    glUniform3f(at.gain, values[0], values[1], values[2]);
    glUniform3f(at.curve, values[3], values[4], values[5]);
    glUniform3f(at.lift, values[6], values[7], values[8]);
    glUniform1f(at.contrast, values[9]); glUniform1f(at.saturation, values[10]);
    const auto one = [](float value) { return value > 0.9995f && value < 1.0005f; };
    glUniform1i(at.curved, one(values[3]) && one(values[4]) && one(values[5]) ? 0 : 1);
}

// FSR 1 RCAS on the driver's RGB: the four neighbours bound the result, so edges gain contrast without
// overshoot (it also holds for PQ and HLG code values, which are perceptual like gamma).
// A strength above 1 is the user asking for more than that: the excess adds the pixel's difference from
// its neighbours without a bound (boost), halos included.
// window: the part of each eye's picture the head faces (centre and half size in eye UV), fading out
// towards its rim; the rest is the plain copy, one sample instead of five. 8K60 affords no more.
// Both are drawn as rectangles of the picture (rect: u0, v0, u1, v1; a four-vertex strip): the window's
// box with this program and the picture around it with the plain one, which costs less than one
// program that tests every pixel (Quest 3, 8K60: about 1.2 ms a frame).
const char* const kRectVertex = "#version 300 es\n"
    "uniform bool flip; uniform vec4 rect; out vec2 uv;\n"
    "void main() { uv = mix(rect.xy, rect.zw, vec2(float(gl_VertexID & 1), float((gl_VertexID >> 1) & 1)));\n"
    "  gl_Position = vec4(uv.x * 2.0 - 1.0, (flip ? 1.0 - uv.y : uv.y) * 2.0 - 1.0, 0.0, 1.0); }\n";

bool ensure_sharp_program() {
    if (sharp_program && part_program) return true;
    const char* vertex = kRectVertex;
    static const char* plain = "#version 300 es\n"
        "#extension GL_OES_EGL_image_external_essl3 : require\n"
        "precision highp float;\n"
        "uniform samplerExternalOES frame; uniform vec2 scale; in vec2 uv; out vec4 result;\n"
        GRADE_GLSL
        "void main() { result = vec4(grade(texture(frame, uv * scale).rgb), 1.0); }\n";
    if (!part_program) {
        part_program = link(vertex, plain);
        if (!part_program) return false;
        part_scale = glGetUniformLocation(part_program, "scale"); part_flip = glGetUniformLocation(part_program, "flip");
        part_rect = glGetUniformLocation(part_program, "rect");
        part_grade = grade_locations(part_program);
        glUseProgram(part_program);
        glUniform1i(glGetUniformLocation(part_program, "frame"), 0);
    }
    if (sharp_program) return true;
    static const char* fragment = "#version 300 es\n"
        "#extension GL_OES_EGL_image_external_essl3 : require\n"
        "precision highp float;\n"
        "uniform samplerExternalOES frame; uniform vec2 scale; uniform vec2 texel; uniform float amount;\n"
        "uniform vec4 window; uniform vec3 eyes; uniform float tint; uniform float boost;\n"
        "in vec2 uv; out vec4 result;\n"
        GRADE_GLSL
        "void main() { vec2 at = uv * scale;\n"
        "  vec3 e = texture(frame, at).rgb;\n"
        "  float weight = 1.0;\n"
        "  if (window.z > 0.0) { vec2 away = fract(uv * eyes.xy) - window.xy;\n"
        "    if (eyes.z > 0.5) away.x = fract(away.x + 0.5) - 0.5;\n"
        "    weight = 1.0 - smoothstep(0.7, 1.0, length(away / window.zw)); }\n"
        "  if (weight <= 0.0) { result = vec4(grade(e), 1.0); return; }\n"
        "  vec3 b = texture(frame, at - vec2(0.0, texel.y)).rgb, h = texture(frame, at + vec2(0.0, texel.y)).rgb;\n"
        "  vec3 d = texture(frame, at - vec2(texel.x, 0.0)).rgb, f = texture(frame, at + vec2(texel.x, 0.0)).rgb;\n"
        "  vec3 low = min(min(b, d), min(f, h)), high = max(max(b, d), max(f, h));\n"
        "  vec3 hit_low = low / max(4.0 * high, vec3(1e-5)), hit_high = (1.0 - high) / min(4.0 * low - 4.0, vec3(-1e-5));\n"
        "  vec3 lobes = max(-hit_low, hit_high);\n"
        "  float lobe = max(-0.1875, min(max(lobes.r, max(lobes.g, lobes.b)), 0.0)) * amount * weight;\n"
        "  vec3 sharp = (lobe * (b + d + f + h) + e) / (4.0 * lobe + 1.0);\n"
        "  sharp = grade(clamp(sharp + (e - 0.25 * (b + d + f + h)) * boost * weight, 0.0, 1.0));\n"
        "  result = vec4(mix(sharp, vec3(1.0, 0.0, 0.0), 0.3 * tint * weight), 1.0); }\n";
    sharp_program = link(vertex, fragment);
    if (!sharp_program) return false;
    sharp_scale = glGetUniformLocation(sharp_program, "scale"); sharp_flip = glGetUniformLocation(sharp_program, "flip");
    sharp_texel = glGetUniformLocation(sharp_program, "texel"); sharp_amount = glGetUniformLocation(sharp_program, "amount");
    sharp_window = glGetUniformLocation(sharp_program, "window"); sharp_eyes = glGetUniformLocation(sharp_program, "eyes");
    sharp_tint = glGetUniformLocation(sharp_program, "tint"); sharp_rect = glGetUniformLocation(sharp_program, "rect");
    sharp_grade = grade_locations(sharp_program);
    sharp_boost = glGetUniformLocation(sharp_program, "boost");
    glUseProgram(sharp_program);
    glUniform1i(glGetUniformLocation(sharp_program, "frame"), 0);
    return true;
}

bool ensure_upscale_programs() {
    if (easu_program && finish_program && denoise_program && easu_texture_program) return true;
    // FSR 1 EASU (AMD FidelityFX, MIT): twelve taps around the output pixel; the luma gradients of the
    // four nearest give an edge direction and length, which turn and stretch a Lanczos-like kernel along
    // the edge; the result stays within those four pixels' range.
    //     b c
    //   e f g h
    //   i j k l
    //     n o
    static const char* easu = "#version 300 es\n"
        "#extension GL_OES_EGL_image_external_essl3 : require\n"
        "precision highp float;\n"
        "uniform samplerExternalOES frame; uniform vec2 source; uniform vec2 extent;\n"
        "in vec2 uv; out vec4 result;\n"
        WINDOW_GLSL
        "vec3 tap(vec2 cell, vec2 offset) { return texture(frame, (cell + offset + 0.5) / extent).rgb; }\n"
        EASU_GLSL;
    // RCAS over the enlarged texture, then the grade; towards the window's rim it gives way to the
    // decoder's picture enlarged bilinearly, which is what the plain program draws around the window.
    static const char* finish = "#version 300 es\n"
        "#extension GL_OES_EGL_image_external_essl3 : require\n"
        "precision highp float;\n"
        "uniform samplerExternalOES frame; uniform sampler2D enlarged; uniform vec2 scale; uniform vec2 texel;\n"
        "uniform float amount; uniform float tint; uniform float boost;\n"
        "in vec2 uv; out vec4 result;\n"
        WINDOW_GLSL
        GRADE_GLSL
        "void main() { vec3 plain = texture(frame, uv * scale).rgb;\n"
        "  float weight = window_weight(uv, 1.0);\n"
        "  if (weight <= 0.0) { result = vec4(grade(plain), 1.0); return; }\n"
        "  vec3 e = texture(enlarged, uv).rgb;\n"
        "  vec3 b = texture(enlarged, uv - vec2(0.0, texel.y)).rgb, h = texture(enlarged, uv + vec2(0.0, texel.y)).rgb;\n"
        "  vec3 d = texture(enlarged, uv - vec2(texel.x, 0.0)).rgb, f = texture(enlarged, uv + vec2(texel.x, 0.0)).rgb;\n"
        "  vec3 low = min(min(b, d), min(f, h)), high = max(max(b, d), max(f, h));\n"
        "  vec3 hit_low = low / max(4.0 * high, vec3(1e-5)), hit_high = (1.0 - high) / min(4.0 * low - 4.0, vec3(-1e-5));\n"
        "  vec3 lobes = max(-hit_low, hit_high);\n"
        "  float lobe = max(-0.1875, min(max(lobes.r, max(lobes.g, lobes.b)), 0.0)) * amount;\n"
        "  vec3 sharp = (lobe * (b + d + f + h) + e) / (4.0 * lobe + 1.0);\n"
        "  sharp = clamp(sharp + (e - 0.25 * (b + d + f + h)) * boost, 0.0, 1.0);\n"
        "  result = vec4(mix(grade(mix(plain, sharp, weight)), vec3(1.0, 0.0, 0.0), 0.3 * tint * weight), 1.0); }\n";
    if (!easu_program) {
        // The enlarged texture's rows follow the picture's: no flip into it, whatever the surface wants.
        easu_program = link(kRectVertex, easu);
        if (!easu_program) return false;
        easu_rect = glGetUniformLocation(easu_program, "rect"); easu_source = glGetUniformLocation(easu_program, "source");
        easu_buffer = glGetUniformLocation(easu_program, "extent"); easu_window = glGetUniformLocation(easu_program, "window");
        easu_eyes = glGetUniformLocation(easu_program, "eyes");
        glUseProgram(easu_program);
        glUniform1i(glGetUniformLocation(easu_program, "frame"), 0);
        glUniform1i(glGetUniformLocation(easu_program, "flip"), 0);
    }
    if (!denoise_program) {
        static const char* denoise = "#version 300 es\n"
            "#extension GL_OES_EGL_image_external_essl3 : require\n"
            "precision highp float;\n"
            "uniform samplerExternalOES frame; uniform vec2 scale; uniform vec2 step; uniform float tolerance;\n"
            "in vec2 uv; out vec4 result;\n"
            WINDOW_GLSL
            "vec3 near(vec2 offset) { return texture(frame, uv * scale + offset * step).rgb; }\n"
            DENOISE_GLSL
            "void main() { result = window_weight(uv, 1.1) <= 0.0 ? vec4(0.0) : vec4(denoised(tolerance), 1.0); }\n";
        denoise_program = link(kRectVertex, denoise);
        if (!denoise_program) return false;
        glUseProgram(denoise_program);
        glUniform1i(glGetUniformLocation(denoise_program, "frame"), 0);
        glUniform1i(glGetUniformLocation(denoise_program, "flip"), 0);
    }
    if (!easu_texture_program) {
        // EASU reading the denoised texture (unit 1) instead of the decoder's frame.
        static const char* easu_texture = "#version 300 es\n"
            "precision highp float;\n"
            "uniform sampler2D frame; uniform vec2 source;\n"
            "in vec2 uv; out vec4 result;\n"
            WINDOW_GLSL
            "vec3 tap(vec2 cell, vec2 offset) { return texelFetch(frame, ivec2(clamp(cell + offset, vec2(0.0), source - 1.0)), 0).rgb; }\n"
            EASU_GLSL;
        easu_texture_program = link(kRectVertex, easu_texture);
        if (!easu_texture_program) return false;
        glUseProgram(easu_texture_program);
        glUniform1i(glGetUniformLocation(easu_texture_program, "frame"), 1);
        glUniform1i(glGetUniformLocation(easu_texture_program, "flip"), 0);
    }
    if (!finish_program) {
        finish_program = link(kRectVertex, finish);
        if (!finish_program) return false;
        finish_rect = glGetUniformLocation(finish_program, "rect"); finish_flip = glGetUniformLocation(finish_program, "flip");
        finish_scale = glGetUniformLocation(finish_program, "scale"); finish_texel = glGetUniformLocation(finish_program, "texel");
        finish_amount = glGetUniformLocation(finish_program, "amount"); finish_window = glGetUniformLocation(finish_program, "window");
        finish_eyes = glGetUniformLocation(finish_program, "eyes"); finish_tint = glGetUniformLocation(finish_program, "tint");
        finish_grade = grade_locations(finish_program);
        finish_boost = glGetUniformLocation(finish_program, "boost");
        glUseProgram(finish_program);
        glUniform1i(glGetUniformLocation(finish_program, "frame"), 0);
        glUniform1i(glGetUniformLocation(finish_program, "enlarged"), 1);
    }
    return true;
}

/** A texture one pass draws for the next (10 bits a channel, like the surface): the denoised picture
 * at the source's size, or EASU's at the output's. Texture unit 1 is left bound to it. */
bool ensure_target(GLuint& texture, GLuint& fbo, int& held_width, int& held_height, int width, int height) {
    if (texture && held_width == width && held_height == height) return true;
    if (fbo) { glDeleteFramebuffers(1, &fbo); fbo = 0; }
    if (texture) { glDeleteTextures(1, &texture); texture = 0; }
    glActiveTexture(GL_TEXTURE1);
    glGenTextures(1, &texture); glBindTexture(GL_TEXTURE_2D, texture);
    glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGB10_A2, width, height);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glActiveTexture(GL_TEXTURE0);
    glGenFramebuffers(1, &fbo); glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0);
    const bool complete = glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    if (!complete) { log(ANDROID_LOG_WARN, "picture pass framebuffer incomplete"); held_width = held_height = 0; return false; }
    held_width = width; held_height = height;
    return true;
}

void draw_box(GLint location, const Box& box) {
    if (box.u1 <= box.u0 || box.v1 <= box.v0) return;
    glUniform4f(location, box.u0, box.v0, box.u1, box.v1);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}

GLuint texture_for(AHardwareBuffer* buffer) {
    for (auto it = cache.begin(); it != cache.end(); ++it) {
        if (it->buffer == buffer) { cache.splice(cache.begin(), cache, it); return cache.front().texture; }
    }
    if (cache.size() >= kCacheLimit) { drop(cache.back()); cache.pop_back(); }
    const EGLint attributes[] = {EGL_IMAGE_PRESERVED_KHR, EGL_TRUE, EGL_NONE};
    EGLImageKHR image = api().create(eglGetCurrentDisplay(), EGL_NO_CONTEXT, EGL_NATIVE_BUFFER_ANDROID, api().client(buffer), attributes);
    if (image == EGL_NO_IMAGE_KHR) { log(ANDROID_LOG_WARN, "decoder EGLImage creation failed"); return 0; }
    GLuint texture = 0;
    glGenTextures(1, &texture);
    glBindTexture(GL_TEXTURE_EXTERNAL_OES, texture);
    api().target(GL_TEXTURE_EXTERNAL_OES, static_cast<GLeglImageOES>(image));
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    AHardwareBuffer_acquire(buffer); // the cache entry keeps the buffer alive with its image
    cache.push_front({buffer, image, texture});
    return texture;
}

// Memory saver: a held frame is kept as a compact copy at the layer window's size (full-size luma and
// half-size chroma, 1.5 bytes a pixel) so its decoder buffer goes straight back to the decoder. The
// copy is BT.709 full range in and out, so the window gets the colours the driver produced.
struct Packed { GLuint luma = 0, chroma = 0, luma_fbo = 0, chroma_fbo = 0; int width = 0, height = 0; };
std::vector<Packed> packed; // copy thread only, by slot
GLuint pack_luma = 0, pack_chroma = 0, unpack = 0;
GLint pack_luma_scale = -1, pack_luma_flip = -1, pack_chroma_scale = -1, pack_chroma_flip = -1;

GLuint link(const char* vertex, const char* fragment) {
    const GLuint vs = compile(GL_VERTEX_SHADER, vertex), fs = compile(GL_FRAGMENT_SHADER, fragment);
    if (!vs || !fs) { if (vs) glDeleteShader(vs); if (fs) glDeleteShader(fs); return 0; }
    GLuint id = glCreateProgram();
    glAttachShader(id, vs); glAttachShader(id, fs); glLinkProgram(id);
    glDeleteShader(vs); glDeleteShader(fs);
    GLint ok = 0; glGetProgramiv(id, GL_LINK_STATUS, &ok);
    if (!ok) { log(ANDROID_LOG_WARN, "pack program does not link"); glDeleteProgram(id); return 0; }
    return id;
}

bool ensure_pack_programs() {
    if (pack_luma && pack_chroma && unpack) return true;
    static const char* vertex = "#version 300 es\n"
        "uniform bool flip; out vec2 uv;\n"
        "void main() { vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));\n"
        "  uv = vec2(p.x, flip ? 1.0 - p.y : p.y); gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0); }\n";
    static const char* luma = "#version 300 es\n"
        "#extension GL_OES_EGL_image_external_essl3 : require\n"
        "precision highp float;\n"
        "uniform samplerExternalOES frame; uniform vec2 scale; in vec2 uv; out vec4 result;\n"
        "void main() { vec3 c = texture(frame, uv * scale).rgb; result = vec4(dot(c, vec3(0.2126, 0.7152, 0.0722)), 0.0, 0.0, 1.0); }\n";
    // Drawn at half size, one bilinear sample at each 2x2 block's centre averages its chroma.
    static const char* chroma = "#version 300 es\n"
        "#extension GL_OES_EGL_image_external_essl3 : require\n"
        "precision highp float;\n"
        "uniform samplerExternalOES frame; uniform vec2 scale; in vec2 uv; out vec4 result;\n"
        "void main() { vec3 c = texture(frame, uv * scale).rgb; float y = dot(c, vec3(0.2126, 0.7152, 0.0722));\n"
        "  result = vec4((c.b - y) / 1.8556 + 0.5, (c.r - y) / 1.5748 + 0.5, 0.0, 1.0); }\n";
    static const char* plain = "#version 300 es\n"
        "out vec2 uv;\n"
        "void main() { vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));\n"
        "  uv = p; gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0); }\n";
    static const char* rgb = "#version 300 es\n"
        "precision highp float;\n"
        "uniform sampler2D luma; uniform sampler2D chroma; in vec2 uv; out vec4 result;\n"
        "void main() { float y = texture(luma, uv).r; vec2 c = texture(chroma, uv).rg - 0.5;\n"
        "  float r = y + 1.5748 * c.y, b = y + 1.8556 * c.x; float g = (y - 0.2126 * r - 0.0722 * b) / 0.7152;\n"
        "  result = vec4(clamp(vec3(r, g, b), 0.0, 1.0), 1.0); }\n";
    if (!pack_luma) pack_luma = link(vertex, luma);
    if (!pack_chroma) pack_chroma = link(vertex, chroma);
    if (!unpack) unpack = link(plain, rgb);
    if (!pack_luma || !pack_chroma || !unpack) return false;
    pack_luma_scale = glGetUniformLocation(pack_luma, "scale"); pack_luma_flip = glGetUniformLocation(pack_luma, "flip");
    pack_chroma_scale = glGetUniformLocation(pack_chroma, "scale"); pack_chroma_flip = glGetUniformLocation(pack_chroma, "flip");
    glUseProgram(pack_luma); glUniform1i(glGetUniformLocation(pack_luma, "frame"), 0);
    glUseProgram(pack_chroma); glUniform1i(glGetUniformLocation(pack_chroma, "frame"), 0);
    glUseProgram(unpack); glUniform1i(glGetUniformLocation(unpack, "luma"), 0); glUniform1i(glGetUniformLocation(unpack, "chroma"), 1);
    return true;
}

void drop(Packed& slot) {
    if (slot.luma_fbo) glDeleteFramebuffers(1, &slot.luma_fbo);
    if (slot.chroma_fbo) glDeleteFramebuffers(1, &slot.chroma_fbo);
    if (slot.luma) glDeleteTextures(1, &slot.luma);
    if (slot.chroma) glDeleteTextures(1, &slot.chroma);
    slot = Packed{};
}

GLuint plane(int width, int height, GLenum format, GLuint& fbo) {
    GLuint texture = 0;
    glGenTextures(1, &texture); glBindTexture(GL_TEXTURE_2D, texture);
    glTexStorage2D(GL_TEXTURE_2D, 1, format, width, height);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glGenFramebuffers(1, &fbo); glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0);
    return texture;
}

Packed* ensure_packed(int slot, int width, int height) {
    if (slot < 0 || slot > 32) return nullptr;
    if (packed.size() <= static_cast<size_t>(slot)) packed.resize(slot + 1);
    Packed& entry = packed[slot];
    if (entry.luma && (entry.width != width || entry.height != height)) drop(entry);
    if (!entry.luma) {
        entry.width = width; entry.height = height;
        entry.luma = plane(width, height, GL_R8, entry.luma_fbo);
        entry.chroma = plane((width + 1) / 2, (height + 1) / 2, GL_RG8, entry.chroma_fbo);
        const bool complete = glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
        glBindFramebuffer(GL_FRAMEBUFFER, entry.luma_fbo);
        if (!complete || glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
            log(ANDROID_LOG_WARN, "packed frame framebuffer incomplete"); drop(entry); return nullptr;
        }
    }
    return &entry;
}

} // namespace

/** The compositor surface's buffers at the video's own size, before the copy's EGL surface: RGBA8, or
 * 10 bits a channel ([deep]) for 10-bit sources. */
extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_VideoLayerNative_setWindowGeometry(JNIEnv* env, jclass, jobject surface, jint width, jint height, jboolean deep) {
    ANativeWindow* window = surface ? ANativeWindow_fromSurface(env, surface) : nullptr;
    if (!window) return JNI_FALSE;
    const int result = ANativeWindow_setBuffersGeometry(window, width, height,
        deep == JNI_TRUE ? AHARDWAREBUFFER_FORMAT_R10G10B10A2_UNORM : AHARDWAREBUFFER_FORMAT_R8G8B8A8_UNORM);
    ANativeWindow_release(window);
    return result == 0 ? JNI_TRUE : JNI_FALSE;
}

/** The colour space the compositor reads the copy's buffers in (an ADataSpace: BT.2020 PQ or HLG, full
 * range), after the copy's EGL surface exists. */
extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_VideoLayerNative_setWindowDataSpace(JNIEnv* env, jclass, jobject surface, jint data_space) {
    ANativeWindow* window = surface ? ANativeWindow_fromSurface(env, surface) : nullptr;
    if (!window) return JNI_FALSE;
    const int result = ANativeWindow_setBuffersDataSpace(window, data_space);
    ANativeWindow_release(window);
    return result == 0 ? JNI_TRUE : JNI_FALSE;
}

/** Draws one decoder buffer over the current EGL surface (the copy thread's context): visible size
 * width x height of a bufferWidth x bufferHeight buffer; flip: the buffer's first row at the top.
 * quality: picture quality mode. Inside window (the whole frame without one) it denoises (denoise_step
 * source pixels between the samples, denoise_tolerance above 0), enlarges with EASU when the output is
 * larger, and sharpens (sharpen above 0); a negative sharpen holds all three back (no direction to
 * centre the window on yet). The grade applies to the whole frame. */
extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_VideoLayerNative_blitBuffer(JNIEnv* env, jclass, jobject hardware_buffer, jint width, jint height,
        jint buffer_width, jint buffer_height, jint out_width, jint out_height, jboolean flip, jboolean quality, jfloat sharpen, jfloatArray window, jfloatArray grade,
        jfloat denoise_step, jfloat denoise_tolerance) {
    if (!hardware_buffer || width <= 0 || height <= 0 || buffer_width < width || buffer_height < height ||
        out_width <= 0 || out_height <= 0 || !api().ready()) return JNI_FALSE;
    AHardwareBuffer* buffer = AHardwareBuffer_fromHardwareBuffer(env, hardware_buffer);
    const bool picture = quality == JNI_TRUE;
    // Work inside the window: any of the three, each on its own.
    const bool larger = out_width > width || out_height > height;
    const bool sharp = picture && sharpen >= 0.0f && (sharpen > 0.0f || denoise_tolerance > 0.0f || larger);
    if (!buffer || !(picture ? ensure_sharp_program() : ensure_program())) return JNI_FALSE;
    const GLuint texture = texture_for(buffer);
    if (!texture) return JNI_FALSE;
    while (glGetError() != GL_NO_ERROR) {}
    if (!timer.checked) {
        timer.checked = true;
        const char* extensions = reinterpret_cast<const char*>(glGetString(GL_EXTENSIONS));
        if (extensions && std::string(extensions).find("GL_EXT_disjoint_timer_query") != std::string::npos) {
            timer.result = reinterpret_cast<Timer::Result>(eglGetProcAddress("glGetQueryObjectui64vEXT"));
            if (timer.result) glGenQueries(1, &timer.query);
        }
    }
    if (timer.query && timer.pending) {
        GLuint ready = 0; glGetQueryObjectuiv(timer.query, GL_QUERY_RESULT_AVAILABLE, &ready);
        if (ready) {
            GLuint64 ns = 0; timer.result(timer.query, GL_QUERY_RESULT, &ns);
            timer.ms = timer.ms == 0.0 ? ns / 1e6 : timer.ms * 0.95 + ns / 1e6 * 0.05;
            timer.pending = false;
        }
    }
    const bool timed = timer.query && !timer.pending;
    if (timed) glBeginQuery(kTimeElapsed, timer.query);
    glViewport(0, 0, out_width, out_height);
    glDisable(GL_BLEND); glDisable(GL_DEPTH_TEST); glDisable(GL_SCISSOR_TEST);
    const float sx = static_cast<float>(width) / buffer_width, sy = static_cast<float>(height) / buffer_height;
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_EXTERNAL_OES, texture);
    jfloat graded[11];
    const bool grading = picture && grade && env->GetArrayLength(grade) >= 11;
    if (grading) env->GetFloatArrayRegion(grade, 0, 11, graded);
    // u, v, half width, half height (eye UV), eyes across, eyes down, longitude wraps, debug tint.
    jfloat area[8] = {0.5f, 0.5f, 0.0f, 0.0f, 1.0f, 1.0f, 0.0f, 0.0f};
    if (sharp && window && env->GetArrayLength(window) >= 8) env->GetFloatArrayRegion(window, 0, 8, area);
    Box inner[4], outer[16]; int boxes = 0, around = 0;
    if (sharp && area[2] > 0.0f && area[3] > 0.0f) {
        // The window's box in each eye's picture; a 360 degree window across the seam takes the full width.
        const int across = area[4] > 1.5f ? 2 : 1, down = area[5] > 1.5f ? 2 : 1;
        const auto clamp01 = [](float value) { return value < 0.0f ? 0.0f : value > 1.0f ? 1.0f : value; };
        const bool seam = area[6] > 0.5f && (area[0] - area[2] < 0.0f || area[0] + area[2] > 1.0f);
        const float u0 = seam ? 0.0f : clamp01(area[0] - area[2]), u1 = seam ? 1.0f : clamp01(area[0] + area[2]);
        const float v0 = clamp01(area[1] - area[3]), v1 = clamp01(area[1] + area[3]);
        for (int row = 0; row < down; ++row) for (int column = 0; column < across; ++column) {
            const Box eye{static_cast<float>(column) / across, static_cast<float>(row) / down,
                          static_cast<float>(column + 1) / across, static_cast<float>(row + 1) / down};
            const float wide = eye.u1 - eye.u0, high = eye.v1 - eye.v0;
            const Box box{eye.u0 + u0 * wide, eye.v0 + v0 * high, eye.u0 + u1 * wide, eye.v0 + v1 * high};
            inner[boxes++] = box;
            outer[around++] = {eye.u0, eye.v0, eye.u1, box.v0};
            outer[around++] = {eye.u0, box.v1, eye.u1, eye.v1};
            outer[around++] = {eye.u0, box.v0, box.u0, box.v1};
            outer[around++] = {box.u1, box.v0, eye.u1, box.v1};
        }
    } else if (sharp) inner[boxes++] = Box{0.0f, 0.0f, 1.0f, 1.0f};
    // How far the sharpening looks, in source pixels. One pixel of an 8K picture is finer than the display
    // shows: at that reach even 500% changed nothing a viewer would notice (Quest 3 captures: detail x1.9
    // there, the views alike). It widens with the strength, to 1.5 pixels at 100% and 3.5 at 500%.
    const float reach = 1.0f + 0.5f * (sharpen > 0.0f ? sharpen : 0.0f);
    // The passes before the surface, each into its own texture, so the surface is drawn in one pass
    // afterwards: the denoised picture at the source's size, then EASU's at the output's.
    bool denoise = sharp && denoise_tolerance > 0.0f, enlarge = sharp && larger;
    if ((denoise || enlarge) && !ensure_upscale_programs()) denoise = enlarge = false;
    if (denoise && !ensure_target(denoised, denoised_fbo, denoised_width, denoised_height, width, height)) denoise = false;
    if (enlarge && !ensure_target(upscaled, upscaled_fbo, upscaled_width, upscaled_height, out_width, out_height)) enlarge = false;
    if (denoise) {
        glBindFramebuffer(GL_FRAMEBUFFER, denoised_fbo);
        glViewport(0, 0, width, height);
        glUseProgram(denoise_program);
        glUniform2f(glGetUniformLocation(denoise_program, "scale"), sx, sy);
        glUniform2f(glGetUniformLocation(denoise_program, "step"), denoise_step / buffer_width, denoise_step / buffer_height);
        glUniform1f(glGetUniformLocation(denoise_program, "tolerance"), denoise_tolerance);
        glUniform4f(glGetUniformLocation(denoise_program, "window"), area[0], area[1], area[2], area[3]);
        glUniform3f(glGetUniformLocation(denoise_program, "eyes"), area[4], area[5], area[6]);
        const GLint rect = glGetUniformLocation(denoise_program, "rect");
        for (int index = 0; index < boxes; ++index) draw_box(rect, inner[index]);
    }
    if (enlarge) {
        glBindFramebuffer(GL_FRAMEBUFFER, upscaled_fbo);
        glViewport(0, 0, out_width, out_height);
        if (denoise) {
            glActiveTexture(GL_TEXTURE1); glBindTexture(GL_TEXTURE_2D, denoised); glActiveTexture(GL_TEXTURE0);
            glUseProgram(easu_texture_program);
            glUniform2f(glGetUniformLocation(easu_texture_program, "source"), static_cast<float>(width), static_cast<float>(height));
            glUniform4f(glGetUniformLocation(easu_texture_program, "window"), area[0], area[1], area[2], area[3]);
            glUniform3f(glGetUniformLocation(easu_texture_program, "eyes"), area[4], area[5], area[6]);
            const GLint rect = glGetUniformLocation(easu_texture_program, "rect");
            for (int index = 0; index < boxes; ++index) draw_box(rect, inner[index]);
        } else {
            glUseProgram(easu_program);
            glUniform2f(easu_source, static_cast<float>(width), static_cast<float>(height));
            glUniform2f(easu_buffer, static_cast<float>(buffer_width), static_cast<float>(buffer_height));
            glUniform4f(easu_window, area[0], area[1], area[2], area[3]);
            glUniform3f(easu_eyes, area[4], area[5], area[6]);
            for (int index = 0; index < boxes; ++index) draw_box(easu_rect, inner[index]);
        }
    }
    if (denoise || enlarge) { glBindFramebuffer(GL_FRAMEBUFFER, 0); glViewport(0, 0, out_width, out_height); }
    if (picture) {
        glUseProgram(part_program);
        glUniform2f(part_scale, sx, sy); glUniform1i(part_flip, flip == JNI_TRUE ? 1 : 0);
        set_grade(part_grade, grading ? graded : nullptr);
        if (!sharp) draw_box(part_rect, Box{0.0f, 0.0f, 1.0f, 1.0f});
        for (int index = 0; index < around; ++index) draw_box(part_rect, outer[index]);
    }
    if (sharp && (enlarge || denoise)) {
        // The finishing program reads whichever texture the passes ended in.
        glUseProgram(finish_program);
        glUniform2f(finish_scale, sx, sy); glUniform1i(finish_flip, flip == JNI_TRUE ? 1 : 0);
        // Neighbours a source pixel away, not an output pixel: at the output's finer pitch the same RCAS
        // sharpened a 1080p picture half as much as it did without the enlargement (Quest 3 captures).
        glUniform2f(finish_texel, reach / width, reach / height);
        glUniform1f(finish_amount, sharpen < 1.0f ? (sharpen > 0.0f ? sharpen : 0.0f) : 1.0f);
        glUniform1f(finish_boost, sharpen > 1.0f ? sharpen - 1.0f : 0.0f);
        glUniform4f(finish_window, area[0], area[1], area[2], area[3]);
        glUniform3f(finish_eyes, area[4], area[5], area[6]);
        glUniform1f(finish_tint, area[7]);
        set_grade(finish_grade, grading ? graded : nullptr);
        glActiveTexture(GL_TEXTURE1); glBindTexture(GL_TEXTURE_2D, enlarge ? upscaled : denoised); glActiveTexture(GL_TEXTURE0);
        for (int index = 0; index < boxes; ++index) draw_box(finish_rect, inner[index]);
    } else if (sharp) {
        glUseProgram(sharp_program);
        glUniform2f(sharp_scale, sx, sy); glUniform1i(sharp_flip, flip == JNI_TRUE ? 1 : 0);
        glUniform2f(sharp_texel, reach / buffer_width, reach / buffer_height);
        glUniform1f(sharp_amount, sharpen < 1.0f ? sharpen : 1.0f);
        glUniform1f(sharp_boost, sharpen > 1.0f ? sharpen - 1.0f : 0.0f);
        glUniform4f(sharp_window, area[0], area[1], area[2], area[3]);
        glUniform3f(sharp_eyes, area[4], area[5], area[6]);
        glUniform1f(sharp_tint, area[7]);
        set_grade(sharp_grade, grading ? graded : nullptr);
        for (int index = 0; index < boxes; ++index) draw_box(sharp_rect, inner[index]);
    } else if (!picture) {
        glUseProgram(program);
        glUniform2f(scale_location, sx, sy);
        glUniform1i(flip_location, flip == JNI_TRUE ? 1 : 0);
        glDrawArrays(GL_TRIANGLES, 0, 3);
    }
    if (timed) { glEndQuery(kTimeElapsed); timer.pending = true; }
    const GLenum error = glGetError();
    if (error != GL_NO_ERROR) { log(ANDROID_LOG_WARN, "blit GL error " + std::to_string(error)); return JNI_FALSE; }
    return JNI_TRUE;
}

/** Smoothed GPU time of one copy in milliseconds (0 until the driver has reported one). */
extern "C" JNIEXPORT jdouble JNICALL
Java_org_vrpassthroughplayer_plugin_VideoLayerNative_blitGpuMs(JNIEnv*, jclass) { return timer.ms; }

/** Memory saver: copies one decoder buffer into packed [slot] at out_width x out_height (copy thread),
 * so the buffer can go back to the decoder while the frame waits for its mask. */
extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_VideoLayerNative_packBuffer(JNIEnv* env, jclass, jobject hardware_buffer, jint width, jint height,
        jint buffer_width, jint buffer_height, jint out_width, jint out_height, jboolean flip, jint slot) {
    if (!hardware_buffer || width <= 0 || height <= 0 || buffer_width < width || buffer_height < height ||
        out_width <= 0 || out_height <= 0 || !api().ready()) return JNI_FALSE;
    AHardwareBuffer* buffer = AHardwareBuffer_fromHardwareBuffer(env, hardware_buffer);
    if (!buffer || !ensure_pack_programs()) return JNI_FALSE;
    const GLuint texture = texture_for(buffer);
    if (!texture) return JNI_FALSE;
    while (glGetError() != GL_NO_ERROR) {}
    Packed* target = ensure_packed(slot, out_width, out_height);
    if (!target) return JNI_FALSE;
    glDisable(GL_BLEND); glDisable(GL_DEPTH_TEST); glDisable(GL_SCISSOR_TEST);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_EXTERNAL_OES, texture);
    const float sx = static_cast<float>(width) / buffer_width, sy = static_cast<float>(height) / buffer_height;
    glBindFramebuffer(GL_FRAMEBUFFER, target->luma_fbo);
    glViewport(0, 0, target->width, target->height);
    glUseProgram(pack_luma); glUniform2f(pack_luma_scale, sx, sy); glUniform1i(pack_luma_flip, flip == JNI_TRUE ? 1 : 0);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    glBindFramebuffer(GL_FRAMEBUFFER, target->chroma_fbo);
    glViewport(0, 0, (target->width + 1) / 2, (target->height + 1) / 2);
    glUseProgram(pack_chroma); glUniform2f(pack_chroma_scale, sx, sy); glUniform1i(pack_chroma_flip, flip == JNI_TRUE ? 1 : 0);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    // The decoder may refill the buffer once it is released: the copy must have read it by then.
    glFinish();
    const GLenum error = glGetError();
    if (error != GL_NO_ERROR) { log(ANDROID_LOG_WARN, "pack GL error " + std::to_string(error)); return JNI_FALSE; }
    return JNI_TRUE;
}

/** Memory saver: draws packed [slot] over the current EGL surface (the layer window). */
extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_VideoLayerNative_drawPacked(JNIEnv*, jclass, jint slot) {
    if (slot < 0 || static_cast<size_t>(slot) >= packed.size() || !packed[slot].luma || !ensure_pack_programs()) return JNI_FALSE;
    const Packed& source = packed[slot];
    while (glGetError() != GL_NO_ERROR) {}
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    glViewport(0, 0, source.width, source.height);
    glDisable(GL_BLEND); glDisable(GL_DEPTH_TEST); glDisable(GL_SCISSOR_TEST);
    glUseProgram(unpack);
    glActiveTexture(GL_TEXTURE1); glBindTexture(GL_TEXTURE_2D, source.chroma);
    glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, source.luma);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    const GLenum error = glGetError();
    if (error != GL_NO_ERROR) { log(ANDROID_LOG_WARN, "unpack GL error " + std::to_string(error)); return JNI_FALSE; }
    return JNI_TRUE;
}

/** The copy thread's GL objects, before its context goes. */
extern "C" JNIEXPORT void JNICALL
Java_org_vrpassthroughplayer_plugin_VideoLayerNative_releaseBlit(JNIEnv*, jclass) {
    for (auto& entry : cache) drop(entry);
    cache.clear();
    for (auto& entry : packed) drop(entry);
    packed.clear();
    if (upscaled_fbo) { glDeleteFramebuffers(1, &upscaled_fbo); upscaled_fbo = 0; }
    if (upscaled) { glDeleteTextures(1, &upscaled); upscaled = 0; }
    upscaled_width = upscaled_height = 0;
    if (denoised_fbo) { glDeleteFramebuffers(1, &denoised_fbo); denoised_fbo = 0; }
    if (denoised) { glDeleteTextures(1, &denoised); denoised = 0; }
    denoised_width = denoised_height = 0;
    for (GLuint* id : {&program, &sharp_program, &part_program, &easu_program, &finish_program, &denoise_program, &easu_texture_program,
                       &pack_luma, &pack_chroma, &unpack}) if (*id) { glDeleteProgram(*id); *id = 0; }
    if (timer.query) glDeleteQueries(1, &timer.query);
    timer = Timer{};
}
