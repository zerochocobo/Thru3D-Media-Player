// Picture quality mode's frame interpolation: the motion between two frames is estimated once for the
// pair, and each display refresh between them draws the picture for its moment.
// The shaders and their order are in interp_glsl.h; tools/frame_interp/harness.py runs the same on a PC.
//
// On the layer copy's thread and EGL context the frames are decoder buffers, and the picture in between
// goes into a buffer of this file's own, which the layer copy then draws to the compositor surface as it
// draws a decoder frame (sharpening, grade and the rest unchanged).
//
// On Godot's context the frames are 2D->3D's stereo pairs (the render bridge's textures, both eyes side
// by side). A pair's texture is its slot's and is drawn over by a later frame, so each pair is copied
// when it arrives. Shown at its own size, the copy is the pair as picture quality mode draws it
// (video_layer.cpp's enhance_frame: denoised, sharpened, graded), made once for the pair, and each
// refresh's picture goes straight into the picture layer's image: one pass over the picture a refresh.
// Enlarged by super resolution, the copy is the pair as it came and the picture in between is a texture
// that draw then reads in a pair's place. Each eye's motion is estimated on its own picture, which
// carries the depth along: nothing here knows the depth map.
#include <jni.h>
#include <android/hardware_buffer.h>
#include <android/hardware_buffer_jni.h>
#include <android/log.h>
#define EGL_EGLEXT_PROTOTYPES
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl32.h>
#include <GLES2/gl2ext.h>
#include <algorithm>
#include <cmath>
#include <string>
#include "interp_glsl.h"
#include "layer_copy.h"

namespace {

void log(int priority, const std::string& text) { __android_log_write(priority, "QuestFrameInterp", text.c_str()); }

constexpr int kLevels = 8;
// Tuned on the harness against real in-between frames (60 fps footage with every other frame left out)
// and MVTools: how much a vector pays to leave its prediction, where a match stops being trusted,
// what counts as a cut, and how firmly the softening holds well-matched cells.
constexpr float kPenalty = 0.004f, kDoubtFrom = 0.012f, kDoubtTo = 0.03f, kCutMatch = 0.03f, kCutRatio = 0.45f, kFirm = 0.004f;
constexpr int kSoftenPasses = 2;
constexpr GLenum kTimeElapsed = 0x88BF; // GL_TIME_ELAPSED_EXT
// Frames whose luma, fields and (for stereo pairs) copies are kept at once: the pair on show, the frame
// after it and one that came early.
constexpr int kFrames = 4, kPairs = kFrames - 1;

struct Luma { GLuint texture = 0; jlong id = -1; };
// One direction's vectors: a texture for each level of the search and two the finishing passes
// alternate between; `result` is the one they ended in, mipmapped for the whole field's mean.
struct Field { GLuint level[kLevels] = {}; GLuint work[2] = {}; GLuint result = 0; };
struct Pair { jlong before = -1, after = -1; Field forward, backward; };
struct Timer {
    GLuint query = 0; bool pending = false; double ms = 0.0;
};
struct Kept { GLuint texture = 0; jlong id = -1; };

struct Engine {
    const bool external; // the frames are decoder images (the layer copy's thread), else textures (Godot's)
    const int split;     // eye pictures across a frame
    int width = 0, height = 0; // the frames' visible size everything below was made for
    int luma_width = 0, luma_height = 0, top = 0;
    int field_width[kLevels] = {}, field_height[kLevels] = {};
    Luma lumas[kFrames]; int next_luma = 0;
    Pair pairs[kPairs]; int next_pair = 0;
    GLuint fbo = 0;
    GLuint luma_program = 0, search_program = 0, refine_program = 0, even_program = 0, soften_program = 0, between_program = 0;
    // The picture in between. Decoder frames: a buffer the layer copy reads like a decoder's (10 bits a
    // channel, like the surface).
    AHardwareBuffer* mixed = nullptr; EGLImageKHR mixed_image = EGL_NO_IMAGE_KHR; GLuint mixed_texture = 0;
    // Stereo pairs: the copies of the pairs, and the picture in between as one more.
    Kept kept[kFrames]; int next_kept = 0;
    bool checked = false, supported = false, failed = false;
    bool srgb_control = false; // EXT_sRGB_write_control: writes to an sRGB image encode only while enabled
    void (*query_result)(GLuint, GLenum, GLuint64*) = nullptr;
    Timer estimate_timer, between_timer;
    // Resolved through EGL like the layer copy's own, not linked.
    PFNEGLGETNATIVECLIENTBUFFERANDROIDPROC client_buffer = nullptr;
    PFNEGLCREATEIMAGEKHRPROC create_image = nullptr;
    PFNEGLDESTROYIMAGEKHRPROC destroy_image = nullptr;
    PFNGLEGLIMAGETARGETTEXTURE2DOESPROC image_target = nullptr;
    Engine(bool external_frames, int eyes) : external(external_frames), split(eyes) {}
    GLenum frame_target() const { return external ? GL_TEXTURE_EXTERNAL_OES : GL_TEXTURE_2D; }
};
Engine copy_engine(true, 1), pair_engine(false, 2);

/** Starts timing the GPU work that follows, unless the last measurement has not come back yet. */
bool begin(Engine& e, Timer& timer) {
    if (!e.query_result) return false;
    if (!timer.query) glGenQueries(1, &timer.query);
    if (timer.pending) {
        GLuint ready = 0; glGetQueryObjectuiv(timer.query, GL_QUERY_RESULT_AVAILABLE, &ready);
        if (!ready) return false;
        GLuint64 ns = 0; e.query_result(timer.query, GL_QUERY_RESULT, &ns);
        timer.ms = timer.ms == 0.0 ? ns / 1e6 : timer.ms * 0.9 + ns / 1e6 * 0.1;
        timer.pending = false;
    }
    glBeginQuery(kTimeElapsed, timer.query);
    return true;
}
struct Timed {
    Timer& timer; bool started;
    Timed(Engine& e, Timer& t) : timer(t), started(begin(e, t)) {}
    ~Timed() { if (started) { glEndQuery(kTimeElapsed); timer.pending = true; } }
};

/** What these draws change on Godot's context, put back afterwards (Godot keeps its own GL state cache). */
struct Saved {
    GLint draw = 0, read = 0, program = 0, array = 0, active = 0, viewport[4] = {}, textures[4] = {}, samplers[4] = {};
    GLboolean blend, scissor, depth, cull, stencil, dither, mask[4] = {};
    Saved() {
        glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &draw); glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &read);
        glGetIntegerv(GL_CURRENT_PROGRAM, &program); glGetIntegerv(GL_VERTEX_ARRAY_BINDING, &array);
        glGetIntegerv(GL_ACTIVE_TEXTURE, &active); glGetIntegerv(GL_VIEWPORT, viewport);
        for (int i = 0; i < 4; ++i) {
            glActiveTexture(GL_TEXTURE0 + i);
            glGetIntegerv(GL_TEXTURE_BINDING_2D, &textures[i]); glGetIntegerv(GL_SAMPLER_BINDING, &samplers[i]);
            glBindSampler(i, 0); // the textures here carry their own filtering
        }
        blend = glIsEnabled(GL_BLEND); scissor = glIsEnabled(GL_SCISSOR_TEST); depth = glIsEnabled(GL_DEPTH_TEST);
        cull = glIsEnabled(GL_CULL_FACE); stencil = glIsEnabled(GL_STENCIL_TEST); dither = glIsEnabled(GL_DITHER);
        glGetBooleanv(GL_COLOR_WRITEMASK, mask);
        glDisable(GL_CULL_FACE); glDisable(GL_STENCIL_TEST); glDisable(GL_DITHER);
        glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
        glBindVertexArray(0);
    }
    static void set(GLenum cap, GLboolean on) { if (on) glEnable(cap); else glDisable(cap); }
    ~Saved() {
        for (int i = 0; i < 4; ++i) {
            glActiveTexture(GL_TEXTURE0 + i);
            glBindTexture(GL_TEXTURE_2D, static_cast<GLuint>(textures[i])); glBindSampler(i, static_cast<GLuint>(samplers[i]));
        }
        glActiveTexture(static_cast<GLenum>(active));
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, static_cast<GLuint>(draw)); glBindFramebuffer(GL_READ_FRAMEBUFFER, static_cast<GLuint>(read));
        glUseProgram(static_cast<GLuint>(program)); glBindVertexArray(static_cast<GLuint>(array));
        glViewport(viewport[0], viewport[1], viewport[2], viewport[3]);
        set(GL_BLEND, blend); set(GL_SCISSOR_TEST, scissor); set(GL_DEPTH_TEST, depth);
        set(GL_CULL_FACE, cull); set(GL_STENCIL_TEST, stencil); set(GL_DITHER, dither);
        glColorMask(mask[0], mask[1], mask[2], mask[3]);
    }
};

GLuint make(GLenum format, int w, int h, int levels, GLenum minify, GLenum magnify) {
    GLuint texture = 0;
    glGenTextures(1, &texture); glBindTexture(GL_TEXTURE_2D, texture);
    glTexStorage2D(GL_TEXTURE_2D, levels, format, w, h);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, minify); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, magnify);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    return texture;
}

int mip_levels(int w, int h) { int levels = 1; for (int side = std::max(w, h); side > 1; side >>= 1) ++levels; return levels; }

void drop(GLuint& texture) { if (texture) { glDeleteTextures(1, &texture); texture = 0; } }

void drop(Field& field) {
    for (GLuint& texture : field.level) drop(texture);
    for (GLuint& texture : field.work) drop(texture);
    field.result = 0;
}

void drop_mixed(Engine& e) {
    drop(e.mixed_texture);
    if (e.mixed) layer_copy::forget(e.mixed);
    if (e.mixed_image != EGL_NO_IMAGE_KHR) { e.destroy_image(eglGetCurrentDisplay(), e.mixed_image); e.mixed_image = EGL_NO_IMAGE_KHR; }
    if (e.mixed) { AHardwareBuffer_release(e.mixed); e.mixed = nullptr; }
}

void drop_sized(Engine& e) {
    for (Luma& luma : e.lumas) { drop(luma.texture); luma.id = -1; }
    for (Pair& pair : e.pairs) { drop(pair.forward); drop(pair.backward); pair.before = pair.after = -1; }
    for (Kept& frame : e.kept) { drop(frame.texture); frame.id = -1; }
    drop_mixed(e);
    e.width = e.height = 0;
}

/** A fragment shader of interp_glsl.h for this engine's frames: textures in the decoder images' place. */
std::string fragment(const Engine& e, const char* source) {
    std::string text = source;
    if (e.external) return text;
    const std::string extension = "#extension GL_OES_EGL_image_external_essl3 : require\n", sampler = "samplerExternalOES";
    for (size_t at; (at = text.find(extension)) != std::string::npos;) text.erase(at, extension.size());
    for (size_t at; (at = text.find(sampler)) != std::string::npos;) text.replace(at, sampler.size(), "sampler2D");
    return text;
}

bool ensure_programs(Engine& e) {
    if (e.between_program) return true;
    if (e.failed) return false;
    if (!e.checked) {
        e.checked = true;
        const char* extensions = reinterpret_cast<const char*>(glGetString(GL_EXTENSIONS));
        const std::string all = extensions ? extensions : "";
        // The vectors and the luma are half floats, drawn into.
        e.supported = all.find("GL_EXT_color_buffer_half_float") != std::string::npos || all.find("GL_EXT_color_buffer_float") != std::string::npos;
        e.srgb_control = all.find("GL_EXT_sRGB_write_control") != std::string::npos;
        if (e.external) {
            if (all.find("GL_EXT_disjoint_timer_query") != std::string::npos)
                e.query_result = reinterpret_cast<void (*)(GLuint, GLenum, GLuint64*)>(eglGetProcAddress("glGetQueryObjectui64vEXT"));
            e.client_buffer = reinterpret_cast<PFNEGLGETNATIVECLIENTBUFFERANDROIDPROC>(eglGetProcAddress("eglGetNativeClientBufferANDROID"));
            e.create_image = reinterpret_cast<PFNEGLCREATEIMAGEKHRPROC>(eglGetProcAddress("eglCreateImageKHR"));
            e.destroy_image = reinterpret_cast<PFNEGLDESTROYIMAGEKHRPROC>(eglGetProcAddress("eglDestroyImageKHR"));
            e.image_target = reinterpret_cast<PFNGLEGLIMAGETARGETTEXTURE2DOESPROC>(eglGetProcAddress("glEGLImageTargetTexture2DOES"));
            e.supported = e.supported && e.client_buffer && e.create_image && e.destroy_image && e.image_target;
        }
        if (!e.supported) log(ANDROID_LOG_WARN, "no half-float render targets: frame interpolation is off");
    }
    if (!e.supported) return false;
    e.luma_program = layer_copy::linked(INTERP_VERTEX_GLSL, fragment(e, INTERP_LUMA_GLSL).c_str());
    e.search_program = layer_copy::linked(INTERP_VERTEX_GLSL, INTERP_SEARCH_GLSL);
    e.refine_program = layer_copy::linked(INTERP_VERTEX_GLSL, INTERP_REFINE_GLSL);
    e.even_program = layer_copy::linked(INTERP_VERTEX_GLSL, INTERP_EVEN_GLSL);
    e.soften_program = layer_copy::linked(INTERP_VERTEX_GLSL, INTERP_SOFTEN_GLSL);
    e.between_program = layer_copy::linked(INTERP_VERTEX_GLSL, fragment(e, INTERP_BETWEEN_GLSL).c_str());
    if (!e.luma_program || !e.search_program || !e.refine_program || !e.even_program || !e.soften_program || !e.between_program) {
        for (GLuint* id : {&e.luma_program, &e.search_program, &e.refine_program, &e.even_program, &e.soften_program, &e.between_program})
            if (*id) { glDeleteProgram(*id); *id = 0; }
        e.failed = true;
        log(ANDROID_LOG_WARN, "frame interpolation shaders do not build");
        return false;
    }
    glUseProgram(e.luma_program); glUniform1i(glGetUniformLocation(e.luma_program, "frame"), 0);
    for (GLuint id : {e.search_program, e.refine_program}) {
        glUseProgram(id);
        glUniform1i(glGetUniformLocation(id, "from"), 0); glUniform1i(glGetUniformLocation(id, "to"), 1);
    }
    glUseProgram(e.search_program); glUniform1i(glGetUniformLocation(e.search_program, "parent"), 2);
    glUniform1f(glGetUniformLocation(e.search_program, "penalty"), kPenalty);
    for (GLuint id : {e.refine_program, e.even_program, e.soften_program}) { glUseProgram(id); glUniform1i(glGetUniformLocation(id, "field"), 2); }
    glUseProgram(e.soften_program); glUniform1f(glGetUniformLocation(e.soften_program, "firm"), kFirm);
    glUseProgram(e.between_program);
    glUniform1i(glGetUniformLocation(e.between_program, "before"), 0); glUniform1i(glGetUniformLocation(e.between_program, "after"), 1);
    glUniform1i(glGetUniformLocation(e.between_program, "forward"), 2); glUniform1i(glGetUniformLocation(e.between_program, "backward"), 3);
    glUniform2f(glGetUniformLocation(e.between_program, "cut"), kCutMatch, kCutRatio);
    glUniform2f(glGetUniformLocation(e.between_program, "doubt"), kDoubtFrom, kDoubtTo);
    for (GLuint id : {e.search_program, e.refine_program, e.even_program, e.soften_program, e.between_program}) {
        glUseProgram(id); glUniform2f(glGetUniformLocation(id, "split"), static_cast<float>(e.split), 1.0f);
    }
    return true;
}

/** The size the search works at: a quarter of a 4K picture's, half of anything up to 2560 across. */
int reduction_of(const Engine& e, int w) { return w / e.split > 2560 ? 4 : 2; }

/** Programs, and the textures for frames of w x h visible pixels. */
bool ensure(Engine& e, int w, int h) {
    if (!ensure_programs(e)) return false;
    if (e.width == w && e.height == h) return true;
    drop_sized(e);
    while (glGetError() != GL_NO_ERROR) {}
    // Everything is sized for one eye picture, then laid side by side: no cell lies across two.
    const int reduction = reduction_of(e, w);
    const int eye_luma = (w / e.split + reduction - 1) / reduction;
    e.luma_width = eye_luma * e.split; e.luma_height = (h + reduction - 1) / reduction;
    // Levels down to about 30 pixels across: the coarsest search reaches two of its pixels each way.
    e.top = std::clamp(static_cast<int>(std::floor(std::log2(eye_luma / 24.0))), 0, kLevels - 1);
    for (int level = 0; level <= e.top; ++level) {
        e.field_width[level] = (std::max(1, eye_luma >> level) + 3) / 4 * e.split;
        e.field_height[level] = (std::max(1, e.luma_height >> level) + 3) / 4;
    }
    // The finest level keeps the grid of the level above it, a vector for each 8 x 8 of its pixels: a
    // third of the whole estimate's GPU time (Quest 3, 4K: 6.8 ms a pair with a vector for each 4 x 4),
    // and within 1 dB of it against real in-between frames.
    if (e.top >= 1) { e.field_width[0] = e.field_width[1]; e.field_height[0] = e.field_height[1]; }
    glActiveTexture(GL_TEXTURE0);
    for (Luma& luma : e.lumas)
        luma.texture = make(GL_R16F, e.luma_width, e.luma_height, mip_levels(e.luma_width, e.luma_height), GL_LINEAR_MIPMAP_NEAREST, GL_LINEAR);
    for (Pair& pair : e.pairs) for (Field* field : {&pair.forward, &pair.backward}) {
        for (int level = 0; level <= e.top; ++level)
            field->level[level] = make(GL_RGBA16F, e.field_width[level], e.field_height[level], 1, GL_NEAREST, GL_NEAREST);
        for (GLuint& texture : field->work)
            texture = make(GL_RGBA16F, e.field_width[0], e.field_height[0], mip_levels(e.field_width[0], e.field_height[0]), GL_LINEAR_MIPMAP_NEAREST, GL_LINEAR);
    }
    if (!e.fbo) glGenFramebuffers(1, &e.fbo);
    if (e.external) {
        glBindTexture(GL_TEXTURE_2D, 0);
        AHardwareBuffer_Desc desc = {};
        desc.width = static_cast<uint32_t>(w); desc.height = static_cast<uint32_t>(h); desc.layers = 1;
        desc.format = AHARDWAREBUFFER_FORMAT_R10G10B10A2_UNORM;
        desc.usage = AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE | AHARDWAREBUFFER_USAGE_GPU_FRAMEBUFFER;
        if (AHardwareBuffer_allocate(&desc, &e.mixed) != 0 || !e.mixed) { e.mixed = nullptr; log(ANDROID_LOG_WARN, "no buffer for the picture in between"); return false; }
        const EGLint attributes[] = {EGL_IMAGE_PRESERVED_KHR, EGL_TRUE, EGL_NONE};
        e.mixed_image = e.create_image(eglGetCurrentDisplay(), EGL_NO_CONTEXT, EGL_NATIVE_BUFFER_ANDROID, e.client_buffer(e.mixed), attributes);
        if (e.mixed_image == EGL_NO_IMAGE_KHR) { drop_mixed(e); log(ANDROID_LOG_WARN, "no image for the picture in between"); return false; }
        glGenTextures(1, &e.mixed_texture); glBindTexture(GL_TEXTURE_2D, e.mixed_texture);
        e.image_target(GL_TEXTURE_2D, static_cast<GLeglImageOES>(e.mixed_image));
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    } else {
        // Encoded values as the pairs hold them (the render bridge's are GL_RGBA8 too). The picture in
        // between gets its texture when one is first asked for (pair_picture).
        for (Kept& frame : e.kept) frame.texture = make(GL_RGBA8, w, h, 1, GL_LINEAR, GL_LINEAR);
    }
    glBindTexture(GL_TEXTURE_2D, 0);
    glBindFramebuffer(GL_FRAMEBUFFER, e.fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, e.external ? e.mixed_texture : e.kept[0].texture, 0);
    const bool complete = glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, e.lumas[0].texture, 0);
    const bool floats = glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    if (!complete || !floats || glGetError() != GL_NO_ERROR) {
        drop_sized(e); log(ANDROID_LOG_WARN, "frame interpolation targets incomplete");
        while (glGetError() != GL_NO_ERROR) {}
        return false;
    }
    e.width = w; e.height = h;
    return true;
}

void target(GLuint texture, int w, int h) {
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0);
    glViewport(0, 0, w, h);
}

GLuint luma_held(const Engine& e, jlong id) {
    for (const Luma& luma : e.lumas) if (luma.id == id) return luma.texture;
    return 0;
}

/** Frame [id]'s reduced luma with its mipmaps, drawn once for the frame from its picture `frame`. */
GLuint luma_of(Engine& e, jlong id, GLuint frame, int buffer_width, int buffer_height) {
    if (const GLuint held = luma_held(e, id)) return held;
    if (!frame) return 0;
    // The frame is the pair's other one more often than not: take the slot after it.
    Luma& luma = e.lumas[e.next_luma]; e.next_luma = (e.next_luma + 1) % kFrames;
    luma.id = id;
    const float reduction = static_cast<float>(reduction_of(e, e.width));
    glActiveTexture(GL_TEXTURE0); glBindTexture(e.frame_target(), frame);
    glUseProgram(e.luma_program);
    glUniform2f(glGetUniformLocation(e.luma_program, "scale"), static_cast<float>(e.width) / buffer_width, static_cast<float>(e.height) / buffer_height);
    glUniform2f(glGetUniformLocation(e.luma_program, "tap"), reduction / 4.0f / buffer_width, reduction / 4.0f / buffer_height);
    target(luma.texture, e.luma_width, e.luma_height);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    glBindTexture(e.frame_target(), 0);
    glBindTexture(GL_TEXTURE_2D, luma.texture); glGenerateMipmap(GL_TEXTURE_2D);
    return luma.texture;
}

/** The motion from luma `from` to luma `to`, coarse to fine, then refined, evened and softened. */
void estimate(Engine& e, Field& field, GLuint from, GLuint to) {
    glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, from);
    glActiveTexture(GL_TEXTURE1); glBindTexture(GL_TEXTURE_2D, to);
    glActiveTexture(GL_TEXTURE2);
    glUseProgram(e.search_program);
    glUniform2f(glGetUniformLocation(e.search_program, "size"), static_cast<float>(e.luma_width), static_cast<float>(e.luma_height));
    const GLint first = glGetUniformLocation(e.search_program, "first"), lod = glGetUniformLocation(e.search_program, "lod"),
        pitch = glGetUniformLocation(e.search_program, "pitch");
    for (int level = e.top; level >= 0; --level) {
        glUniform1i(first, level == e.top ? 1 : 0);
        glUniform1f(lod, static_cast<float>(level)); glUniform1f(pitch, static_cast<float>(1 << level));
        glBindTexture(GL_TEXTURE_2D, level == e.top ? 0 : field.level[level + 1]);
        target(field.level[level], e.field_width[level], e.field_height[level]);
        glDrawArrays(GL_TRIANGLES, 0, 3);
    }
    glUseProgram(e.refine_program);
    glUniform2f(glGetUniformLocation(e.refine_program, "size"), static_cast<float>(e.luma_width), static_cast<float>(e.luma_height));
    glUniform1f(glGetUniformLocation(e.refine_program, "lod"), 0.0f); glUniform1f(glGetUniformLocation(e.refine_program, "pitch"), 1.0f);
    glBindTexture(GL_TEXTURE_2D, field.level[0]);
    target(field.work[0], e.field_width[0], e.field_height[0]);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    int source = 0;
    glUseProgram(e.even_program);
    glBindTexture(GL_TEXTURE_2D, field.work[source]); target(field.work[1 - source], e.field_width[0], e.field_height[0]);
    glDrawArrays(GL_TRIANGLES, 0, 3); source = 1 - source;
    glUseProgram(e.soften_program);
    for (int pass = 0; pass < kSoftenPasses; ++pass) {
        glBindTexture(GL_TEXTURE_2D, field.work[source]); target(field.work[1 - source], e.field_width[0], e.field_height[0]);
        glDrawArrays(GL_TRIANGLES, 0, 3); source = 1 - source;
    }
    field.result = field.work[source];
    glBindTexture(GL_TEXTURE_2D, field.result); glGenerateMipmap(GL_TEXTURE_2D);
    glBindTexture(GL_TEXTURE_2D, 0);
    glActiveTexture(GL_TEXTURE1); glBindTexture(GL_TEXTURE_2D, 0);
    glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, 0);
}

Pair* pair_of(Engine& e, jlong before, jlong after) {
    for (Pair& pair : e.pairs) if (pair.before == before && pair.after == after && pair.forward.result && pair.backward.result) return &pair;
    return nullptr;
}

/** The motion both ways between the frames `first` and `second` (their pictures; ids name them): a pair
 * already estimated returns at once, and the pairs estimated last are kept. Needs ensure() to have passed. */
bool estimate_pair(Engine& e, GLuint first, GLuint second, jlong before_id, jlong after_id, int buffer_width, int buffer_height) {
    if (pair_of(e, before_id, after_id)) return true;
    while (glGetError() != GL_NO_ERROR) {}
    Timed timed(e, e.estimate_timer);
    glDisable(GL_BLEND); glDisable(GL_DEPTH_TEST); glDisable(GL_SCISSOR_TEST);
    glBindFramebuffer(GL_FRAMEBUFFER, e.fbo);
    const GLuint from = luma_of(e, before_id, first, buffer_width, buffer_height);
    const GLuint to = luma_of(e, after_id, second, buffer_width, buffer_height);
    bool done = false;
    if (from && to) {
        // The pairs still on show keep their fields: the slot used longest ago takes this one.
        Pair& pair = e.pairs[e.next_pair]; e.next_pair = (e.next_pair + 1) % kPairs;
        pair.before = before_id; pair.after = after_id;
        estimate(e, pair.forward, from, to);
        estimate(e, pair.backward, to, from);
        done = true;
    }
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    const GLenum error = glGetError();
    if (error != GL_NO_ERROR) { log(ANDROID_LOG_WARN, "estimate GL error " + std::to_string(error)); return false; }
    return done;
}

/** Draws the picture at phase between the frames `first` and `second` into `into` (the frames' size): the
 * engine's `mixed`, or an sRGB image (`linear`: it takes linear light). `only` 1 or 2 draws `first` or
 * `second` as it is; `pair` may then be null. */
bool between(Engine& e, GLuint first, GLuint second, const Pair* pair, float phase, int buffer_width, int buffer_height,
             GLuint into, bool linear = false, int only = 0) {
    if (!first || !second || !into || (!pair && !only)) return false;
    while (glGetError() != GL_NO_ERROR) {}
    Timed timed(e, e.between_timer);
    glDisable(GL_BLEND); glDisable(GL_DEPTH_TEST); glDisable(GL_SCISSOR_TEST);
    glBindFramebuffer(GL_FRAMEBUFFER, e.fbo);
    target(into, e.width, e.height);
    glUseProgram(e.between_program);
    glUniform1i(glGetUniformLocation(e.between_program, "only"), only);
    glUniform1i(glGetUniformLocation(e.between_program, "linear_output"), linear ? 1 : 0);
    glUniform2f(glGetUniformLocation(e.between_program, "scale"), static_cast<float>(e.width) / buffer_width, static_cast<float>(e.height) / buffer_height);
    glUniform2f(glGetUniformLocation(e.between_program, "size"), static_cast<float>(e.luma_width), static_cast<float>(e.luma_height));
    glUniform1f(glGetUniformLocation(e.between_program, "phase"), phase);
    // One picture's edge is the texture's own; an eye's edge inside a pair is half a pixel from the other eye.
    glUniform2f(glGetUniformLocation(e.between_program, "margin"), e.split > 1 ? 0.5f / e.width : 0.0f, e.split > 1 ? 0.5f / e.height : 0.0f);
    glActiveTexture(GL_TEXTURE3); glBindTexture(GL_TEXTURE_2D, pair ? pair->backward.result : 0);
    glActiveTexture(GL_TEXTURE2); glBindTexture(GL_TEXTURE_2D, pair ? pair->forward.result : 0);
    glActiveTexture(GL_TEXTURE1); glBindTexture(e.frame_target(), second);
    glActiveTexture(GL_TEXTURE0); glBindTexture(e.frame_target(), first);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    glActiveTexture(GL_TEXTURE3); glBindTexture(GL_TEXTURE_2D, 0);
    glActiveTexture(GL_TEXTURE2); glBindTexture(GL_TEXTURE_2D, 0);
    glActiveTexture(GL_TEXTURE1); glBindTexture(e.frame_target(), 0);
    glActiveTexture(GL_TEXTURE0); glBindTexture(e.frame_target(), 0);
    // The image is not this file's: it leaves the framebuffer before its owner hands it on.
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, 0, 0);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    const GLenum error = glGetError();
    if (error != GL_NO_ERROR) { log(ANDROID_LOG_WARN, "between GL error " + std::to_string(error)); return false; }
    return true;
}

void release_engine(Engine& e) {
    if (e.checked) drop_sized(e);
    if (e.fbo) { glDeleteFramebuffers(1, &e.fbo); e.fbo = 0; }
    for (GLuint* id : {&e.luma_program, &e.search_program, &e.refine_program, &e.even_program, &e.soften_program, &e.between_program})
        if (*id) { glDeleteProgram(*id); *id = 0; }
    for (Timer* timer : {&e.estimate_timer, &e.between_timer}) { if (timer->query) glDeleteQueries(1, &timer->query); *timer = Timer{}; }
    e.checked = e.supported = e.failed = false; e.query_result = nullptr;
    e.client_buffer = nullptr; e.create_image = nullptr; e.destroy_image = nullptr; e.image_target = nullptr;
}

Kept* kept_of(Engine& e, jlong id) {
    if (id < 0) return nullptr;
    for (Kept& frame : e.kept) if (frame.id == id && frame.texture) return &frame;
    return nullptr;
}

} // namespace

void frame_interp::release() { release_engine(copy_engine); }

GLuint frame_interp::pair_slot(int width, int height, jlong id) {
    Engine& e = pair_engine;
    if (width < 2 || height < 1 || (width & 1) || id < 0) return 0;
    Saved saved;
    if (!ensure(e, width, height)) return 0;
    Kept* frame = kept_of(e, id);
    if (!frame) {
        // The oldest copy goes: the frames on show are the newest.
        frame = &e.kept[e.next_kept]; e.next_kept = (e.next_kept + 1) % kFrames;
        frame->id = id;
        for (Luma& luma : e.lumas) if (luma.id == id) luma.id = -1; // an id met again names another picture
    }
    return frame->texture;
}

void frame_interp::pair_forget(jlong id) {
    if (Kept* frame = kept_of(pair_engine, id)) frame->id = -1;
}

bool frame_interp::pair_estimate(jlong id, jlong before_id) {
    Engine& e = pair_engine;
    const Kept* frame = kept_of(e, id);
    if (!frame) return false;
    const Kept* before = kept_of(e, before_id);
    if (!before) return true;
    Saved saved;
    return estimate_pair(e, before->texture, frame->texture, before_id, id, e.width, e.height);
}

bool frame_interp::pair_push(GLuint texture, int width, int height, jlong id, jlong before_id) {
    if (!texture || !glIsTexture(texture)) return false;
    const GLuint copy = pair_slot(width, height, id);
    if (!copy) return false;
    while (glGetError() != GL_NO_ERROR) {}
    glCopyImageSubData(texture, GL_TEXTURE_2D, 0, 0, 0, 0, copy, GL_TEXTURE_2D, 0, 0, 0, 0, width, height, 1);
    const GLenum error = glGetError();
    if (error != GL_NO_ERROR) {
        pair_forget(id);
        log(ANDROID_LOG_WARN, "stereo pair copy GL error " + std::to_string(error) + " at " + std::to_string(width) + "x" + std::to_string(height));
        return false;
    }
    // The pair's motion now, so its first refresh finds it done.
    return pair_estimate(id, before_id);
}

bool frame_interp::pair_show(GLuint image, jlong before_id, jlong after_id, float phase) {
    Engine& e = pair_engine;
    const Kept* first = kept_of(e, before_id);
    const Kept* second = kept_of(e, after_id);
    if (!image || (!first && !second)) return false;
    Saved saved;
    constexpr GLenum kFramebufferSrgb = 0x8DB9; // GL_FRAMEBUFFER_SRGB_EXT
    const GLboolean encoding = e.srgb_control ? glIsEnabled(kFramebufferSrgb) : GL_TRUE;
    if (e.srgb_control) glEnable(kFramebufferSrgb);
    // Without its motion (the frames came faster than they showed) the nearer frame shows as it is.
    const Pair* pair = first && second ? pair_of(e, before_id, after_id) : nullptr;
    int only = 0;
    if (!second || (first && phase <= 0.0f)) only = 1;
    else if (!first || phase >= 1.0f) only = 2;
    else if (!pair) only = phase < 0.5f ? 1 : 2;
    const GLuint a = first ? first->texture : second->texture, b = second ? second->texture : first->texture;
    const bool drawn = between(e, a, b, pair, phase, e.width, e.height, image, true, only);
    if (e.srgb_control && !encoding) glDisable(kFramebufferSrgb);
    return drawn;
}

GLuint frame_interp::pair_picture(jlong before_id, jlong after_id, float phase) {
    Engine& e = pair_engine;
    Kept* first = kept_of(e, before_id);
    Kept* second = kept_of(e, after_id);
    if (!first && !second) return 0;
    if (!second || (first && phase <= 0.0f)) return first->texture;
    if (!first || phase >= 1.0f) return second->texture;
    Saved saved;
    if (!e.mixed_texture) { glActiveTexture(GL_TEXTURE0); e.mixed_texture = make(GL_RGBA8, e.width, e.height, 1, GL_LINEAR, GL_LINEAR); }
    // Without its motion (the frames came faster than they showed) the nearer frame shows as it is.
    const Pair* pair = pair_of(e, before_id, after_id);
    if (!pair || !between(e, first->texture, second->texture, pair, phase, e.width, e.height, e.mixed_texture))
        return phase < 0.5f ? first->texture : second->texture;
    return e.mixed_texture;
}

void frame_interp::pair_release() {
    if (!pair_engine.checked) return;
    release_engine(pair_engine);
    while (glGetError() != GL_NO_ERROR) {}
}

/** Estimates the motion between two decoder frames (copy thread), each known by an id that stays with
 * the frame; a pair already estimated returns at once. The pairs estimated last are kept. */
extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_VideoLayerNative_interpEstimate(JNIEnv* env, jclass, jobject before, jobject after, jlong before_id, jlong after_id,
        jint w, jint h, jint buffer_width, jint buffer_height) {
    if (!before || !after || w <= 0 || h <= 0 || buffer_width < w || buffer_height < h) return JNI_FALSE;
    Engine& e = copy_engine;
    if (!ensure(e, w, h)) return JNI_FALSE;
    if (pair_of(e, before_id, after_id)) return JNI_TRUE;
    const GLuint first = layer_copy::texture(AHardwareBuffer_fromHardwareBuffer(env, before));
    const GLuint second = layer_copy::texture(AHardwareBuffer_fromHardwareBuffer(env, after));
    return first && second && estimate_pair(e, first, second, before_id, after_id, buffer_width, buffer_height) ? JNI_TRUE : JNI_FALSE;
}

/** VideoLayerNative.blitBuffer for the moment `phase` (0..1) between two decoder frames: the picture in
 * between is drawn first, then drawn to the surface as a frame is. */
extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_VideoLayerNative_interpBlit(JNIEnv* env, jclass, jobject before, jobject after, jlong before_id, jlong after_id,
        jfloat phase, jint w, jint h, jint buffer_width, jint buffer_height, jint out_width, jint out_height, jboolean flip, jboolean quality,
        jfloat sharpen, jfloatArray window, jfloatArray grade, jfloat denoise_step, jfloat denoise_tolerance) {
    if (!before || !after || w <= 0 || h <= 0 || buffer_width < w || buffer_height < h) return JNI_FALSE;
    Engine& e = copy_engine;
    if (!ensure(e, w, h)) return JNI_FALSE;
    const GLuint first = layer_copy::texture(AHardwareBuffer_fromHardwareBuffer(env, before));
    const GLuint second = layer_copy::texture(AHardwareBuffer_fromHardwareBuffer(env, after));
    if (!first || !second || !estimate_pair(e, first, second, before_id, after_id, buffer_width, buffer_height)) return JNI_FALSE;
    const Pair* pair = pair_of(e, before_id, after_id);
    if (!pair || !between(e, first, second, pair, std::clamp(phase, 0.0f, 1.0f), buffer_width, buffer_height, e.mixed_texture)) return JNI_FALSE;
    return layer_copy::blit(env, e.mixed, w, h, w, h, out_width, out_height, flip, quality, sharpen, window, grade, denoise_step, denoise_tolerance)
        ? JNI_TRUE : JNI_FALSE;
}

/** Smoothed GPU milliseconds: of one pair's estimate (which 0), of one picture in between (1). */
extern "C" JNIEXPORT jdouble JNICALL
Java_org_vrpassthroughplayer_plugin_VideoLayerNative_interpGpuMs(JNIEnv*, jclass, jint which) {
    return which == 0 ? copy_engine.estimate_timer.ms : copy_engine.between_timer.ms;
}
