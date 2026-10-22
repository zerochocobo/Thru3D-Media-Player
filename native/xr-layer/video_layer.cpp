// Video composition layers: the decoder writes into an OpenXR Android-surface swapchain and the
// runtime compositor samples it once at display time, instead of Godot drawing the video into the
// eye buffers. Godot owns the instance, session and frame loop; a script registers itself as a
// composition layer provider and hands Godot the addresses of the structs kept here.
//
// Stereo: one swapchain (MediaCodec has one output surface), two layers with eye visibility
// LEFT/RIGHT and their halves as imageRect. Godot's own layer nodes cannot share a swapchain or
// set imageRect, hence this provider.
//
// A second, RGBA swapchain carries pictures Godot already has on the GPU or in memory: the 2D->3D
// stereo pair of each video frame (a GPU copy) and photos (uploaded in slices across frames, then
// mipmapped on the GPU), so the compositor samples those once as well. Its GL calls run on Godot's
// render thread with Godot's context current; the touched GL state is restored.
#include <jni.h>
#include <android/log.h>
#include <array>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <mutex>
#include <stdexcept>
#include <string>
#define XR_USE_PLATFORM_ANDROID
#include <EGL/egl.h>
#include <GLES3/gl32.h>
#include <GLES2/gl2ext.h>
#include <vector>
#define XR_USE_GRAPHICS_API_OPENGL_ES
#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>
#include "layer_layout.h"
#include "layer_extensions.h"
#include "pip_shader_sources.h"

namespace {
constexpr int kMaxLayers = 16; // hard storage bound; the caller also budgets every runtime/provider layer
constexpr int kStride = 28; // floats per layer in setLayers()
/** Picture swapchain slots: 0 photos and 2D->3D pairs, 1 subtitles, 2 the photo magnifier. */
constexpr int kSlots = 4; // slot 3 is the shared three-window, two-eye PiP atlas
struct Picture {
    XrSwapchain image = XR_NULL_HANDLE;
    std::vector<GLuint> textures;
    int width = 0, height = 0, levels = 0;
    bool is_static = false;
    GLuint acquired = 0; // texture of the acquired image, 0 when none
};
union Layer {
    XrCompositionLayerBaseHeader base;
    XrCompositionLayerQuad quad;
    XrCompositionLayerCylinderKHR cylinder;
    XrCompositionLayerEquirect2KHR equirect;
};
struct State {
    XrInstance instance = XR_NULL_HANDLE;
    XrSession session = XR_NULL_HANDLE;
    XrSpace space = XR_NULL_HANDLE;
    PFN_xrGetInstanceProcAddr get_proc = nullptr;
    PFN_xrCreateSwapchainAndroidSurfaceKHR create_surface = nullptr;
    PFN_xrDestroySwapchain destroy_swapchain = nullptr;
    XrSwapchain swapchain = XR_NULL_HANDLE;
    jobject surface = nullptr; // global reference, valid while the swapchain lives
    int width = 0, height = 0;
    XrSystemGraphicsProperties limits{};
    std::array<Layer, kMaxLayers> layers{};
    // Next-chain structs of each layer (XR_FB extensions Godot's vendors plugin enables on Meta runtimes).
    std::array<XrCompositionLayerImageLayoutFB, kMaxLayers> layouts{};
    std::array<XrCompositionLayerSettingsFB, kMaxLayers> settings{};
    std::array<XrCompositionLayerColorScaleBiasKHR, kMaxLayers> colors{};
    std::array<XrCompositionLayerAlphaBlendFB, kMaxLayers> blends{};
    std::array<uint64_t, kMaxLayers> logged_layout{};
    int count = 0;
    // RGBA picture swapchains (2D->3D pairs, photos, subtitles).
    PFN_xrCreateSwapchain create_swapchain = nullptr;
    PFN_xrEnumerateSwapchainImages enumerate_images = nullptr;
    PFN_xrAcquireSwapchainImage acquire_image = nullptr;
    PFN_xrWaitSwapchainImage wait_image = nullptr;
    PFN_xrReleaseSwapchainImage release_image = nullptr;
    std::array<Picture, kSlots> pictures{};
};
std::mutex mutex;
State state;

void log(int priority, const std::string& text) { __android_log_write(priority, "QuestVideoLayer", text.c_str()); }
void fail(JNIEnv* env, const char* text) {
    log(ANDROID_LOG_ERROR, text);
    if (!env->ExceptionCheck()) env->ThrowNew(env->FindClass("java/lang/IllegalStateException"), text);
}
template <typename T> T proc(const char* name) {
    PFN_xrVoidFunction function = nullptr;
    if (XR_FAILED(state.get_proc(state.instance, name, &function)) || !function) throw std::runtime_error(std::string("OpenXR function unavailable: ") + name);
    return reinterpret_cast<T>(function);
}
Picture* picture(int slot) { return slot >= 0 && slot < kSlots ? &state.pictures[slot] : nullptr; }
void release_pip_projection();
void destroy_image(Picture& p) {
    if (&p == &state.pictures[0]) release_pip_projection();
    if (p.image != XR_NULL_HANDLE) {
        if (p.acquired && state.release_image) {
            XrSwapchainImageReleaseInfo info{}; info.type = XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO;
            state.release_image(p.image, &info);
        }
        if (state.destroy_swapchain) state.destroy_swapchain(p.image);
    }
    p = Picture{};
}
/** Layers may still name a picture swapchain about to go: never submit a destroyed handle. */
void drop_layers_of(const Picture& p) {
    for (int i = 0; i < state.count; ++i) {
        if (p.image != XR_NULL_HANDLE && state.layers[i].quad.subImage.swapchain == p.image) { state.count = 0; break; }
    }
}
/** Restores the GL state the picture uploads and copies touch (Godot keeps its own cache). */
struct GlState {
    GLint texture = 0, unpack = 0, alignment = 0, row_length = 0, skip_rows = 0, skip_pixels = 0, active = 0;
    GlState() {
        glGetIntegerv(GL_ACTIVE_TEXTURE, &active); glActiveTexture(GL_TEXTURE0);
        glGetIntegerv(GL_TEXTURE_BINDING_2D, &texture); glGetIntegerv(GL_PIXEL_UNPACK_BUFFER_BINDING, &unpack);
        glGetIntegerv(GL_UNPACK_ALIGNMENT, &alignment); glGetIntegerv(GL_UNPACK_ROW_LENGTH, &row_length);
        glGetIntegerv(GL_UNPACK_SKIP_ROWS, &skip_rows); glGetIntegerv(GL_UNPACK_SKIP_PIXELS, &skip_pixels);
    }
    ~GlState() {
        glBindTexture(GL_TEXTURE_2D, static_cast<GLuint>(texture)); glBindBuffer(GL_PIXEL_UNPACK_BUFFER, static_cast<GLuint>(unpack));
        glPixelStorei(GL_UNPACK_ALIGNMENT, alignment); glPixelStorei(GL_UNPACK_ROW_LENGTH, row_length);
        glPixelStorei(GL_UNPACK_SKIP_ROWS, skip_rows); glPixelStorei(GL_UNPACK_SKIP_PIXELS, skip_pixels);
        glActiveTexture(static_cast<GLenum>(active));
    }
};
/** Premultiplied cutout: colour x soft mask, drawn (the swapchain is sRGB: the shader works in linear light). */
GLuint masked_program = 0;
GLuint compile(GLenum type, const char* source) {
    const GLuint shader = glCreateShader(type);
    glShaderSource(shader, 1, &source, nullptr); glCompileShader(shader);
    GLint ok = 0; glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char text[512] = {}; glGetShaderInfoLog(shader, sizeof(text) - 1, nullptr, text);
        log(ANDROID_LOG_WARN, std::string("masked copy shader: ") + text);
        glDeleteShader(shader); return 0;
    }
    return shader;
}
GLuint masked_copy_program() {
    if (masked_program && glIsProgram(masked_program)) return masked_program;
    static const char* vertex = "#version 300 es\n"
        "void main() { vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2)); gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0); }\n";
    // Matches the photo shader: alpha = smoothstep(0.02, 0.98, mask) times the colour's own alpha.
    static const char* fragment = "#version 300 es\n"
        "precision highp float;\n"
        "uniform sampler2D color_band; uniform sampler2D mask_band; uniform int first_row;\n"
        "out vec4 result;\n"
        "vec3 to_linear(vec3 c) { return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c)); }\n"
        "void main() {\n"
        "  ivec2 at = ivec2(gl_FragCoord.xy) - ivec2(0, first_row);\n"
        "  vec4 c = texelFetch(color_band, at, 0);\n"
        "  float a = smoothstep(0.02, 0.98, texelFetch(mask_band, at, 0).r) * c.a;\n"
        "  result = vec4(to_linear(c.rgb) * a, a);\n"
        "}\n";
    const GLuint vs = compile(GL_VERTEX_SHADER, vertex), fs = compile(GL_FRAGMENT_SHADER, fragment);
    if (!vs || !fs) { if (vs) glDeleteShader(vs); if (fs) glDeleteShader(fs); return 0; }
    masked_program = glCreateProgram();
    glAttachShader(masked_program, vs); glAttachShader(masked_program, fs); glLinkProgram(masked_program);
    glDeleteShader(vs); glDeleteShader(fs);
    GLint ok = 0; glGetProgramiv(masked_program, GL_LINK_STATUS, &ok);
    if (!ok) { log(ANDROID_LOG_WARN, "masked copy program does not link"); glDeleteProgram(masked_program); masked_program = 0; }
    return masked_program;
}
/** Alpha plan B: RVM's packed R8 mask (left | right model eyes) drawn over the whole frame layout into
 * the mask swapchain as (0, 0, 0, m), sampled exactly as video_rvm_pair.gdshader: eye UV -> model UV by
 * rect, nothing outside the model window (ROI), texel centres kept inside the content and this eye. */
GLuint mask_program = 0;
GLuint mask_draw_program() {
    if (mask_program && glIsProgram(mask_program)) return mask_program;
    static const char* vertex = "#version 300 es\n"
        "void main() { vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2)); gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0); }\n";
    static const char* fragment = "#version 300 es\n"
        "precision highp float;\n"
        "uniform sampler2D mask; uniform vec4 rect; uniform int frame_layout; uniform vec2 model_size; uniform vec2 target;\n"
        "uniform vec2 edge; // the player's edge feather/shrink: mask values remapped from [edge.x, edge.y] to [0, 1]\n"
        "out vec4 result;\n"
        "void main() {\n"
        "  vec2 uv = gl_FragCoord.xy / target; // row 0 is the picture's top, as for every GL picture here\n"
        "  float eye = 0.0; vec2 local = uv;\n"
        "  if (frame_layout == 1) { eye = step(0.5, uv.x); local.x = uv.x * 2.0 - eye; }\n"
        "  else if (frame_layout == 2) { eye = step(0.5, uv.y); local.y = uv.y * 2.0 - eye; }\n"
        "  vec2 model_p = rect.xy + local * rect.zw;\n"
        "  if (any(lessThan(model_p, vec2(0.0))) || any(greaterThan(model_p, vec2(1.0)))) { result = vec4(0.0); return; }\n"
        "  vec2 first_center = max((ceil(rect.xy * model_size - vec2(0.5)) + vec2(0.5)) / model_size, vec2(0.5) / model_size);\n"
        "  vec2 last_center = min((floor((rect.xy + rect.zw) * model_size - vec2(0.5)) + vec2(0.5)) / model_size, vec2(1.0) - vec2(0.5) / model_size);\n"
        "  vec2 p = clamp(model_p, first_center, last_center);\n"
        "  float m = clamp((texture(mask, vec2((p.x + eye) * 0.5, p.y)).r - edge.x) / max(edge.y - edge.x, 0.001), 0.0, 1.0);\n"
        "  result = vec4(0.0, 0.0, 0.0, m);\n"
        "}\n";
    const GLuint vs = compile(GL_VERTEX_SHADER, vertex), fs = compile(GL_FRAGMENT_SHADER, fragment);
    if (!vs || !fs) { if (vs) glDeleteShader(vs); if (fs) glDeleteShader(fs); return 0; }
    mask_program = glCreateProgram();
    glAttachShader(mask_program, vs); glAttachShader(mask_program, fs); glLinkProgram(mask_program);
    glDeleteShader(vs); glDeleteShader(fs);
    GLint ok = 0; glGetProgramiv(mask_program, GL_LINK_STATUS, &ok);
    if (!ok) { log(ANDROID_LOG_WARN, "mask program does not link"); glDeleteProgram(mask_program); mask_program = 0; }
    return mask_program;
}
uint64_t mask_version = 0; // masks drawn into the mask swapchain (Godot shows the mask layer once > 0)
/** Everything the masked draw changes, restored afterwards (Godot keeps its own GL state cache). */
struct DrawState {
    GLint framebuffer = 0, program = 0, array = 0, active = 0, viewport[4] = {}, textures[3] = {}, samplers[3] = {};
    GLboolean blend, scissor, depth, cull, stencil, dither, mask[4] = {}, srgb = GL_TRUE;
    // GLES encodes writes to sRGB images unless EXT_sRGB_write_control turned that off.
    static bool srgb_control() {
        static const bool present = [] {
            GLint count = 0; glGetIntegerv(GL_NUM_EXTENSIONS, &count);
            for (GLint i = 0; i < count; ++i) {
                const char* name = reinterpret_cast<const char*>(glGetStringi(GL_EXTENSIONS, static_cast<GLuint>(i)));
                if (name && std::strcmp(name, "GL_EXT_sRGB_write_control") == 0) return true;
            }
            return false;
        }();
        return present;
    }
    static constexpr GLenum kFramebufferSrgb = 0x8DB9; // GL_FRAMEBUFFER_SRGB_EXT
    DrawState() {
        if (srgb_control()) { srgb = glIsEnabled(kFramebufferSrgb); glEnable(kFramebufferSrgb); }
        glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &framebuffer); glGetIntegerv(GL_CURRENT_PROGRAM, &program);
        glGetIntegerv(GL_VERTEX_ARRAY_BINDING, &array); glGetIntegerv(GL_ACTIVE_TEXTURE, &active); glGetIntegerv(GL_VIEWPORT, viewport);
        for (int i = 0; i < 3; ++i) {
            glActiveTexture(GL_TEXTURE0 + i);
            glGetIntegerv(GL_TEXTURE_BINDING_2D, &textures[i]); glGetIntegerv(GL_SAMPLER_BINDING, &samplers[i]);
        }
        blend = glIsEnabled(GL_BLEND); scissor = glIsEnabled(GL_SCISSOR_TEST); depth = glIsEnabled(GL_DEPTH_TEST);
        cull = glIsEnabled(GL_CULL_FACE); stencil = glIsEnabled(GL_STENCIL_TEST); dither = glIsEnabled(GL_DITHER);
        glGetBooleanv(GL_COLOR_WRITEMASK, mask);
    }
    static void set(GLenum cap, GLboolean on) { if (on) glEnable(cap); else glDisable(cap); }
    ~DrawState() {
        for (int i = 0; i < 3; ++i) {
            glActiveTexture(GL_TEXTURE0 + i);
            glBindTexture(GL_TEXTURE_2D, static_cast<GLuint>(textures[i])); glBindSampler(i, static_cast<GLuint>(samplers[i]));
        }
        glActiveTexture(static_cast<GLenum>(active));
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, static_cast<GLuint>(framebuffer)); glUseProgram(static_cast<GLuint>(program));
        glBindVertexArray(static_cast<GLuint>(array)); glViewport(viewport[0], viewport[1], viewport[2], viewport[3]);
        set(GL_BLEND, blend); set(GL_SCISSOR_TEST, scissor); set(GL_DEPTH_TEST, depth);
        set(GL_CULL_FACE, cull); set(GL_STENCIL_TEST, stencil); set(GL_DITHER, dither);
        glColorMask(mask[0], mask[1], mask[2], mask[3]);
        if (srgb_control()) set(kFramebufferSrgb, srgb);
    }
};
void destroy(JNIEnv* env) {
    state.count = 0;
    if (state.swapchain != XR_NULL_HANDLE && state.destroy_swapchain) state.destroy_swapchain(state.swapchain);
    state.swapchain = XR_NULL_HANDLE;
    if (state.surface) env->DeleteGlobalRef(state.surface);
    state.surface = nullptr; state.width = state.height = 0;
}
XrPosef pose(const float* v) {
    XrPosef p{};
    p.position = {v[0], v[1], v[2]};
    p.orientation = {v[3], v[4], v[5], v[6]};
    return p;
}
} // namespace

extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_VideoLayerNative_bind(JNIEnv* env, jclass, jlong instance, jlong session, jlong get_proc, jlong space) {
    std::lock_guard<std::mutex> lock(mutex);
    try {
        if (!instance || !session || !get_proc || !space) throw std::runtime_error("OpenXR handles unavailable");
        const auto new_session = reinterpret_cast<XrSession>(static_cast<uintptr_t>(session));
        // A different session invalidates its swapchain; the caller recreates the surface.
        if (state.session != XR_NULL_HANDLE && state.session != new_session) { destroy(env); for (auto& p : state.pictures) destroy_image(p); }
        state.instance = reinterpret_cast<XrInstance>(static_cast<uintptr_t>(instance));
        state.session = new_session;
        state.space = reinterpret_cast<XrSpace>(static_cast<uintptr_t>(space));
        state.get_proc = reinterpret_cast<PFN_xrGetInstanceProcAddr>(static_cast<uintptr_t>(get_proc));
        state.logged_layout = {};
        state.create_surface = proc<PFN_xrCreateSwapchainAndroidSurfaceKHR>("xrCreateSwapchainAndroidSurfaceKHR");
        state.destroy_swapchain = proc<PFN_xrDestroySwapchain>("xrDestroySwapchain");
        state.create_swapchain = proc<PFN_xrCreateSwapchain>("xrCreateSwapchain");
        state.enumerate_images = proc<PFN_xrEnumerateSwapchainImages>("xrEnumerateSwapchainImages");
        state.acquire_image = proc<PFN_xrAcquireSwapchainImage>("xrAcquireSwapchainImage");
        state.wait_image = proc<PFN_xrWaitSwapchainImage>("xrWaitSwapchainImage");
        state.release_image = proc<PFN_xrReleaseSwapchainImage>("xrReleaseSwapchainImage");
        XrSystemGetInfo system_info{}; system_info.type = XR_TYPE_SYSTEM_GET_INFO;
        system_info.formFactor = XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY;
        XrSystemId system_id = XR_NULL_SYSTEM_ID;
        XrSystemProperties properties{}; properties.type = XR_TYPE_SYSTEM_PROPERTIES;
        if (XR_FAILED(proc<PFN_xrGetSystem>("xrGetSystem")(state.instance, &system_info, &system_id)) ||
            XR_FAILED(proc<PFN_xrGetSystemProperties>("xrGetSystemProperties")(state.instance, system_id, &properties)))
            throw std::runtime_error("Cannot query compositor layer/atlas limits");
        state.limits = properties.graphicsProperties;
        return JNI_TRUE;
    } catch (const std::exception& failure) {
        log(ANDROID_LOG_WARN, failure.what());
        state.create_surface = nullptr;
        return JNI_FALSE;
    }
}

/** Returns the producer Surface of a new swapchain (the previous one is destroyed). */
extern "C" JNIEXPORT jobject JNICALL
Java_org_vrpassthroughplayer_plugin_VideoLayerNative_createSurface(JNIEnv* env, jclass, jint width, jint height) {
    std::lock_guard<std::mutex> lock(mutex);
    if (!state.create_surface || state.session == XR_NULL_HANDLE) { fail(env, "Video layer is not bound to an OpenXR session"); return nullptr; }
    if (width <= 0 || height <= 0 || width > 16384 || height > 16384) { fail(env, "Video layer surface size invalid"); return nullptr; }
    destroy(env);
    XrSwapchainCreateInfo info{};
    info.type = XR_TYPE_SWAPCHAIN_CREATE_INFO;
    // The producer defines the buffers: format, sample/face/array/mip counts must be zero (as Godot's own
    // Android-surface layers create them; Quest rejects other values with a validation failure).
    info.usageFlags = XR_SWAPCHAIN_USAGE_SAMPLED_BIT | XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT | XR_SWAPCHAIN_USAGE_MUTABLE_FORMAT_BIT;
    info.width = static_cast<uint32_t>(width); info.height = static_cast<uint32_t>(height);
    XrSwapchain swapchain = XR_NULL_HANDLE; jobject surface = nullptr;
    const XrResult result = state.create_surface(state.session, &info, &swapchain, &surface);
    if (XR_FAILED(result) || swapchain == XR_NULL_HANDLE || !surface) {
        fail(env, ("xrCreateSwapchainAndroidSurfaceKHR failed: " + std::to_string(result)).c_str());
        return nullptr;
    }
    state.swapchain = swapchain; state.surface = env->NewGlobalRef(surface);
    state.width = width; state.height = height;
    return env->NewLocalRef(state.surface);
}

extern "C" JNIEXPORT void JNICALL
Java_org_vrpassthroughplayer_plugin_VideoLayerNative_destroySurface(JNIEnv* env, jclass) {
    std::lock_guard<std::mutex> lock(mutex);
    destroy(env);
}

/** Per layer (kStride floats): type (0 quad, 1 cylinder, 2 equirect), eye (0 both, 1 left, 2 right),
 * pose position xyz + orientation xyzw, imageRect x y w h in swapchain pixels, then the shape:
 * quad width height; cylinder radius centralAngle aspectRatio; equirect radius centralHorizontalAngle
 * upperVerticalAngle lowerVerticalAngle. Angles in radians. Then 17: -1 to omit image layout,
 * 0 to explicitly disable flipping, 1 to flip the image vertically
 * (XR_FB_composition_layer_image_layout: determined separately for Surface and GL pictures), 18: XrCompositionLayerSettingsFB
 * flags (supersampling/sharpening, 0 for none). The caller passes those only when the extensions are
 * enabled. 19: source, 0 the decoder surface, 1 the RGBA picture swapchain. 20-22: colour scale RGB,
 * 23-25: colour bias RGB (XR_KHR_composition_layer_color_scale_bias, ignored unless Godot enabled it;
 * identity 1 1 1 / 0 0 0 adds nothing). 26: picture slot (0-2) of a picture source. 27: blending, bit 0 the
 * texture's alpha (premultiplied), bit 1 unpremultiplied alpha; 0 opaque. Bits 2 and 3 (callers set them
 * only with XR_FB_composition_layer_alpha_blend enabled) mask the next layer up: bit 2 writes the mask,
 * destination colour x (1 - a) and destination alpha = a; bit 3 adds its colour x destination alpha,
 * leaving the alpha. Together: video x m + what lay beneath x (1 - m). count 0 hides the layers. */
extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_VideoLayerNative_setLayers(JNIEnv* env, jclass, jint count, jfloatArray values) {
    std::lock_guard<std::mutex> lock(mutex);
    if (count < 0 || count > kMaxLayers || (state.limits.maxLayerCount && static_cast<uint32_t>(count) > state.limits.maxLayerCount) || !values || env->GetArrayLength(values) < count * kStride) {
        log(ANDROID_LOG_WARN, "setLayers: bad count " + std::to_string(count)); return JNI_FALSE;
    }
    std::array<float, kMaxLayers * kStride> v{};
    env->GetFloatArrayRegion(values, 0, count * kStride, v.data());
    for (int i = 0; i < count * kStride; ++i) if (!std::isfinite(v[i])) {
        log(ANDROID_LOG_WARN, "setLayers: value " + std::to_string(i) + " not finite"); return JNI_FALSE;
    }
    for (int i = 0; i < count; ++i) {
        // A picture layer shows only a released image: never one still being written.
        const bool is_picture = v[i * kStride + 19] > 0.5f;
        const Picture* slot = picture(static_cast<int>(std::lround(v[i * kStride + 26])));
        if (is_picture && !slot) { log(ANDROID_LOG_WARN, "setLayers: picture slot invalid"); return JNI_FALSE; }
        const XrSwapchain source = is_picture ? slot->image : state.swapchain;
        if (source == XR_NULL_HANDLE || (is_picture && slot->acquired)) {
            log(ANDROID_LOG_WARN, std::string("setLayers: ") + (is_picture ? "picture" : "surface") + " swapchain " +
                (source == XR_NULL_HANDLE ? "missing" : "still acquired"));
            return JNI_FALSE;
        }
        if (!quest::image_rect_valid(v.data() + i * kStride + 9,
                                    is_picture ? slot->width : state.width,
                                    is_picture ? slot->height : state.height)) {
            state.count = 0; // never leave a previously submitted unsafe layer visible
            log(ANDROID_LOG_WARN, "setLayers: image rectangle outside swapchain");
            return JNI_FALSE;
        }
    }
    for (int i = 0; i < count; ++i) {
        const float* p = v.data() + i * kStride;
        const int type = static_cast<int>(p[0]), eye = static_cast<int>(p[1]);
        if (type < 0 || type > 2 || eye < 0 || eye > 2) {
            log(ANDROID_LOG_WARN, "setLayers: type/eye " + std::to_string(type) + "/" + std::to_string(eye)); return JNI_FALSE;
        }
        XrSwapchainSubImage sub{};
        sub.swapchain = p[19] > 0.5f ? picture(static_cast<int>(std::lround(p[26])))->image : state.swapchain;
        sub.imageRect = {{static_cast<int32_t>(std::lround(p[9])), static_cast<int32_t>(std::lround(p[10]))},
                         {static_cast<int32_t>(std::lround(p[11])), static_cast<int32_t>(std::lround(p[12]))}};
        const XrEyeVisibility visibility = eye == 1 ? XR_EYE_VISIBILITY_LEFT : (eye == 2 ? XR_EYE_VISIBILITY_RIGHT : XR_EYE_VISIBILITY_BOTH);
        // The runtime corrects chromatic aberration for the layer as for eye buffers. Video is opaque;
        // subtitles and portrait cut-outs blend by their (premultiplied) alpha.
        const int blend = static_cast<int>(std::lround(p[27]));
        XrCompositionLayerFlags flags = XR_COMPOSITION_LAYER_CORRECT_CHROMATIC_ABERRATION_BIT;
        if (blend & 1) flags |= XR_COMPOSITION_LAYER_BLEND_TEXTURE_SOURCE_ALPHA_BIT;
        if (blend & 2) flags |= XR_COMPOSITION_LAYER_UNPREMULTIPLIED_ALPHA_BIT;
        const void* next = quest::image_layout_next(state.layouts[i], p[17], nullptr);
        const auto settings_flags = static_cast<XrCompositionLayerSettingsFlagsFB>(std::lround(p[18]));
        if (settings_flags) {
            state.settings[i] = {};
            state.settings[i].type = XR_TYPE_COMPOSITION_LAYER_SETTINGS_FB;
            state.settings[i].next = next;
            state.settings[i].layerFlags = settings_flags;
            next = &state.settings[i];
        }
        const bool graded = p[20] != 1.0f || p[21] != 1.0f || p[22] != 1.0f || p[23] != 0.0f || p[24] != 0.0f || p[25] != 0.0f;
        if (graded && thru3d_color_scale_bias_enabled()) {
            state.colors[i] = {};
            state.colors[i].type = XR_TYPE_COMPOSITION_LAYER_COLOR_SCALE_BIAS_KHR;
            state.colors[i].next = next;
            state.colors[i].colorScale = {p[20], p[21], p[22], 1.0f};
            state.colors[i].colorBias = {p[23], p[24], p[25], 0.0f};
            next = &state.colors[i];
        }
        if (blend & 12) {
            XrCompositionLayerAlphaBlendFB& factors = state.blends[i];
            factors = {};
            factors.type = XR_TYPE_COMPOSITION_LAYER_ALPHA_BLEND_FB;
            factors.next = const_cast<void*>(next);
            if (blend & 4) {
                factors.srcFactorColor = XR_BLEND_FACTOR_ZERO_FB; factors.dstFactorColor = XR_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA_FB;
                factors.srcFactorAlpha = XR_BLEND_FACTOR_ONE_FB; factors.dstFactorAlpha = XR_BLEND_FACTOR_ZERO_FB;
            } else {
                factors.srcFactorColor = XR_BLEND_FACTOR_DST_ALPHA_FB; factors.dstFactorColor = XR_BLEND_FACTOR_ONE_FB;
                factors.srcFactorAlpha = XR_BLEND_FACTOR_ZERO_FB; factors.dstFactorAlpha = XR_BLEND_FACTOR_ONE_FB;
            }
            next = &factors;
        }
        Layer& layer = state.layers[i];
        std::memset(&layer, 0, sizeof(layer));
        if (type == 0) {
            layer.quad = {XR_TYPE_COMPOSITION_LAYER_QUAD, nullptr, flags, state.space, visibility, sub, pose(p + 2), {p[13], p[14]}};
        } else if (type == 1) {
            layer.cylinder = {XR_TYPE_COMPOSITION_LAYER_CYLINDER_KHR, nullptr, flags, state.space, visibility, sub, pose(p + 2), p[13], p[14], p[15]};
        } else {
            layer.equirect = {XR_TYPE_COMPOSITION_LAYER_EQUIRECT2_KHR, nullptr, flags, state.space, visibility, sub, pose(p + 2), p[13], p[14], p[15], p[16]};
        }
        layer.base.next = next;
        const uint64_t layout_mode = p[17] < 0.0f ? 0 : (p[17] > 0.5f ? 2 : 1);
        const uint64_t config = static_cast<uint64_t>(type) | (p[19] > 0.5f ? 4u : 0u) |
            (layout_mode << 3) | (settings_flags << 5) | (static_cast<uint64_t>(eye) << 16);
        if (state.logged_layout[i] != config) {
            state.logged_layout[i] = config;
            log(ANDROID_LOG_INFO, "Layer=" + std::to_string(i) + "; type=" + std::to_string(type) +
                "; source=" + (p[19] > 0.5f ? "picture" : "Surface") +
                "; image_layout=" + (layout_mode ? "explicit" : "omitted") +
                "; vertical_flip=" + (layout_mode == 2 ? "1" : "0"));
        }
    }
    state.count = count;
    return JNI_TRUE;
}

extern "C" JNIEXPORT jint JNICALL
Java_org_vrpassthroughplayer_plugin_VideoLayerNative_layerCount(JNIEnv*, jclass) {
    std::lock_guard<std::mutex> lock(mutex);
    return state.count;
}

/** Godot created its instance with XR_KHR_composition_layer_color_scale_bias (layer_extensions.cpp). */
extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_VideoLayerNative_colorScaleBias(JNIEnv*, jclass) {
    return thru3d_color_scale_bias_enabled() ? JNI_TRUE : JNI_FALSE;
}

/** The runtime's instance extensions, space separated (diagnostics: which layer features exist). */
extern "C" JNIEXPORT jstring JNICALL
Java_org_vrpassthroughplayer_plugin_VideoLayerNative_runtimeExtensions(JNIEnv* env, jclass) {
    std::string names;
    std::lock_guard<std::mutex> lock(mutex);
    PFN_xrVoidFunction function = nullptr;
    if (state.get_proc && XR_SUCCEEDED(state.get_proc(XR_NULL_HANDLE, "xrEnumerateInstanceExtensionProperties", &function)) && function) {
        auto enumerate = reinterpret_cast<PFN_xrEnumerateInstanceExtensionProperties>(function);
        uint32_t count = 0;
        if (XR_SUCCEEDED(enumerate(nullptr, 0, &count, nullptr)) && count > 0) {
            XrExtensionProperties blank{};
            blank.type = XR_TYPE_EXTENSION_PROPERTIES;
            std::vector<XrExtensionProperties> properties(count, blank);
            if (XR_SUCCEEDED(enumerate(nullptr, count, &count, properties.data()))) {
                for (uint32_t i = 0; i < count; ++i) {
                    if (!names.empty()) names += ' ';
                    names += properties[i].extensionName;
                }
            }
        }
    }
    return env->NewStringUTF(names.c_str());
}

/** Stable address of layer i, read by Godot's frame end on its render thread. */
extern "C" JNIEXPORT jlong JNICALL
Java_org_vrpassthroughplayer_plugin_VideoLayerNative_layerAddress(JNIEnv*, jclass, jint index) {
    if (index < 0 || index >= kMaxLayers) return 0;
    return static_cast<jlong>(reinterpret_cast<uintptr_t>(&state.layers[index]));
}

/** A new RGBA picture swapchain (sRGB, like the pictures Godot holds); the previous one is destroyed.
 * levels: mip levels (photos); isStatic: written once (photos) instead of once per frame. */
extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_VideoLayerNative_createImage(JNIEnv* env, jclass, jint slot, jint width, jint height, jint levels, jboolean is_static) {
    std::lock_guard<std::mutex> lock(mutex);
    Picture* target = picture(slot);
    if (!target) { fail(env, "Picture slot invalid"); return JNI_FALSE; }
    Picture& p = *target;
    if (!state.create_swapchain || state.session == XR_NULL_HANDLE) { fail(env, "Picture layer is not bound to an OpenXR session"); return JNI_FALSE; }
    if (width <= 0 || height <= 0 || width > 16384 || height > 16384 || levels < 1 || levels > 15) { fail(env, "Picture layer size invalid"); return JNI_FALSE; }
    if (p.image != XR_NULL_HANDLE && p.width == width && p.height == height &&
        p.levels == levels && p.is_static == (is_static == JNI_TRUE) && !p.is_static) return JNI_TRUE;
    drop_layers_of(p);
    destroy_image(p);
    XrSwapchainCreateInfo info{};
    info.type = XR_TYPE_SWAPCHAIN_CREATE_INFO;
    info.createFlags = is_static == JNI_TRUE ? XR_SWAPCHAIN_CREATE_STATIC_IMAGE_BIT : 0;
    info.usageFlags = XR_SWAPCHAIN_USAGE_SAMPLED_BIT | XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT | XR_SWAPCHAIN_USAGE_TRANSFER_DST_BIT;
    info.format = GL_SRGB8_ALPHA8;
    info.sampleCount = 1; info.faceCount = 1; info.arraySize = 1;
    info.width = static_cast<uint32_t>(width); info.height = static_cast<uint32_t>(height); info.mipCount = static_cast<uint32_t>(levels);
    XrResult result = state.create_swapchain(state.session, &info, &p.image);
    if (XR_FAILED(result)) { fail(env, ("xrCreateSwapchain failed: " + std::to_string(result)).c_str()); p.image = XR_NULL_HANDLE; return JNI_FALSE; }
    uint32_t count = 0;
    state.enumerate_images(p.image, 0, &count, nullptr);
    std::vector<XrSwapchainImageOpenGLESKHR> images(count);
    for (auto& image : images) { image = {}; image.type = XR_TYPE_SWAPCHAIN_IMAGE_OPENGL_ES_KHR; }
    result = state.enumerate_images(p.image, count, &count, reinterpret_cast<XrSwapchainImageBaseHeader*>(images.data()));
    if (XR_FAILED(result) || count == 0) { destroy_image(p); fail(env, "Picture swapchain images unavailable"); return JNI_FALSE; }
    for (const auto& image : images) p.textures.push_back(image.image);
    p.width = width; p.height = height; p.levels = levels; p.is_static = is_static == JNI_TRUE;
    return JNI_TRUE;
}

extern "C" JNIEXPORT void JNICALL
Java_org_vrpassthroughplayer_plugin_VideoLayerNative_destroyImage(JNIEnv*, jclass, jint slot) {
    std::lock_guard<std::mutex> lock(mutex);
    Picture* p = picture(slot);
    if (!p) return;
    drop_layers_of(*p);
    destroy_image(*p);
}

/** Acquires (and waits for) the next picture image; its GL texture name, 0 on failure. */
extern "C" JNIEXPORT jint JNICALL
Java_org_vrpassthroughplayer_plugin_VideoLayerNative_acquireImage(JNIEnv*, jclass, jint slot) {
    std::lock_guard<std::mutex> lock(mutex);
    Picture* target = picture(slot);
    if (!target) return 0;
    Picture& p = *target;
    if (p.image == XR_NULL_HANDLE || p.acquired) return static_cast<jint>(p.acquired);
    XrSwapchainImageAcquireInfo acquire{}; acquire.type = XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO;
    uint32_t index = 0;
    if (XR_FAILED(state.acquire_image(p.image, &acquire, &index)) || index >= p.textures.size()) return 0;
    XrSwapchainImageWaitInfo wait{}; wait.type = XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO; wait.timeout = XR_INFINITE_DURATION;
    if (XR_FAILED(state.wait_image(p.image, &wait))) {
        XrSwapchainImageReleaseInfo release{}; release.type = XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO;
        state.release_image(p.image, &release);
        return 0;
    }
    p.acquired = p.textures[index];
    return static_cast<jint>(p.acquired);
}

/** Generates the mip chain of the acquired image (when it has levels) and releases it to the compositor. */
extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_VideoLayerNative_releaseImage(JNIEnv*, jclass, jint slot, jboolean mipmaps) {
    std::lock_guard<std::mutex> lock(mutex);
    Picture* target = picture(slot);
    if (!target || !target->acquired) return JNI_FALSE;
    Picture& p = *target;
    if (mipmaps == JNI_TRUE && p.levels > 1) {
        GlState saved;
        glBindTexture(GL_TEXTURE_2D, p.acquired); glGenerateMipmap(GL_TEXTURE_2D);
    }
    XrSwapchainImageReleaseInfo release{}; release.type = XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO;
    const bool ok = XR_SUCCEEDED(state.release_image(p.image, &release));
    p.acquired = 0;
    return ok && glGetError() == GL_NO_ERROR ? JNI_TRUE : JNI_FALSE;
}

/** Rows [y, y + rows) of level 0 of the acquired image from tightly packed RGBA8 (channels 4) or
 * RGB8 (channels 3, expanded here: JPEG photos decode to RGB, a full RGBA copy would double memory). */
extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_VideoLayerNative_uploadRows(JNIEnv* env, jclass, jint slot, jint y, jint rows, jbyteArray pixels, jint channels) {
    std::lock_guard<std::mutex> lock(mutex);
    Picture* target = picture(slot);
    if (!target) return JNI_FALSE;
    Picture& p = *target;
    if (!p.acquired || !pixels || y < 0 || rows <= 0 || y + rows > p.height || (channels != 3 && channels != 4) ||
        env->GetArrayLength(pixels) != static_cast<jsize>(rows) * p.width * channels) return JNI_FALSE;
    using Clock = std::chrono::steady_clock;
    const auto t0 = Clock::now();
    jbyte* source = env->GetByteArrayElements(pixels, nullptr);
    if (!source) return JNI_FALSE;
    const auto t1 = Clock::now();
    std::vector<jbyte> expanded;
    const jbyte* data = source;
    if (channels == 3) {
        const size_t count = static_cast<size_t>(rows) * p.width;
        expanded.resize(count * 4);
        for (size_t i = 0; i < count; ++i) {
            expanded[i * 4] = source[i * 3]; expanded[i * 4 + 1] = source[i * 3 + 1];
            expanded[i * 4 + 2] = source[i * 3 + 2]; expanded[i * 4 + 3] = static_cast<jbyte>(0xff);
        }
        data = expanded.data();
    }
    const auto t2 = Clock::now();
    {
        GlState saved;
        glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
        glPixelStorei(GL_UNPACK_ALIGNMENT, 1); glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
        glPixelStorei(GL_UNPACK_SKIP_ROWS, 0); glPixelStorei(GL_UNPACK_SKIP_PIXELS, 0);
        glBindTexture(GL_TEXTURE_2D, p.acquired);
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, y, p.width, rows, GL_RGBA, GL_UNSIGNED_BYTE, data);
    }
    const auto t3 = Clock::now();
    env->ReleaseByteArrayElements(pixels, source, JNI_ABORT);
    const auto us = [](auto a, auto b) { return std::to_string(std::chrono::duration_cast<std::chrono::microseconds>(b - a).count()); };
    if (y == 0) log(ANDROID_LOG_INFO, "uploadRows first slice: elements " + us(t0, t1) + "us expand " + us(t1, t2) + "us gl " + us(t2, t3) + "us");
    return glGetError() == GL_NO_ERROR ? JNI_TRUE : JNI_FALSE;
}

/** GPU copy of a whole RGBA8 GL_TEXTURE_2D band (image width x rows) into level 0 of the acquired image at row y:
 * photos arrive as Godot textures of a few rows each, so no pixel data crosses JNI. */
extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_VideoLayerNative_copyBand(JNIEnv*, jclass, jint slot, jint texture, jint y, jint rows) {
    std::lock_guard<std::mutex> lock(mutex);
    Picture* target = picture(slot);
    if (!target) return JNI_FALSE;
    Picture& p = *target;
    if (!p.acquired || texture <= 0 || y < 0 || rows <= 0 || y + rows > p.height || !glIsTexture(static_cast<GLuint>(texture)))
        return JNI_FALSE;
    while (glGetError() != GL_NO_ERROR) {}
    glCopyImageSubData(static_cast<GLuint>(texture), GL_TEXTURE_2D, 0, 0, 0, 0,
                       p.acquired, GL_TEXTURE_2D, 0, 0, y, 0, p.width, rows, 1);
    const GLenum error = glGetError();
    if (error != GL_NO_ERROR) log(ANDROID_LOG_WARN, "copyBand GL error " + std::to_string(error));
    return error == GL_NO_ERROR ? JNI_TRUE : JNI_FALSE;
}

/** GPU copy of a whole GL_TEXTURE_2D (same size, RGBA8) into level 0 of the acquired image. */
extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_VideoLayerNative_copyTexture(JNIEnv*, jclass, jint slot, jint texture) {
    std::lock_guard<std::mutex> lock(mutex);
    Picture* target = picture(slot);
    if (!target) return JNI_FALSE;
    Picture& p = *target;
    if (!p.acquired || texture <= 0 || !glIsTexture(static_cast<GLuint>(texture))) {
        log(ANDROID_LOG_WARN, "copyTexture: texture " + std::to_string(texture) + " not copyable (acquired " + std::to_string(p.acquired) + ")");
        return JNI_FALSE;
    }
    while (glGetError() != GL_NO_ERROR) {}
    glCopyImageSubData(static_cast<GLuint>(texture), GL_TEXTURE_2D, 0, 0, 0, 0,
                       p.acquired, GL_TEXTURE_2D, 0, 0, 0, 0, p.width, p.height, 1);
    const GLenum error = glGetError();
    if (error != GL_NO_ERROR) {
        GLint format = 0, width = 0, height = 0;
        { GlState saved; glBindTexture(GL_TEXTURE_2D, static_cast<GLuint>(texture));
          glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, GL_TEXTURE_INTERNAL_FORMAT, &format);
          glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, GL_TEXTURE_WIDTH, &width); glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, GL_TEXTURE_HEIGHT, &height); }
        log(ANDROID_LOG_WARN, "copyTexture GL error " + std::to_string(error) + " source format 0x" + std::to_string(format) + " " + std::to_string(width) + "x" + std::to_string(height) + " into " + std::to_string(p.width) + "x" + std::to_string(p.height));
    }
    return error == GL_NO_ERROR ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jstring JNICALL
Java_org_vrpassthroughplayer_plugin_VideoLayerNative_compositorLimits(JNIEnv* env, jclass) {
    std::lock_guard<std::mutex> lock(mutex);
    const auto& p = state.limits;
    return env->NewStringUTF((std::to_string(p.maxLayerCount) + " " + std::to_string(p.maxSwapchainImageWidth) + " " + std::to_string(p.maxSwapchainImageHeight)).c_str());
}

namespace {
struct PipUniform { const char* name; int components; bool integer; };
// Packed request ABI: 43 common floats followed by three windows of 16 floats.
constexpr PipUniform pip_common[] = {
    {"video_geometry",1,true}, {"stereo_sbs",1,true}, {"top_bottom",1,true}, {"stereo_half",1,true},
    {"swap_eyes",1,true}, {"viewing_eye",1,true}, {"rotation_degrees",1,true}, {"fisheye_fov",1,false},
    {"source_size",2,false}, {"color_uv_scale",2,false}, {"stereo_offset",2,false},
    {"alpha_enabled",1,true}, {"depth_enabled",1,true}, {"depth_shift",1,false}, {"depth_convergence",1,false},
    {"alpha_edge",2,false}, {"model_size",2,false}, {"model_content_rect",4,false},
    {"packed_alpha",1,true}, {"packed_size",2,false}, {"packed_color",1,true}, {"grade_enabled",1,true},
    {"grade_gain",3,false}, {"grade_gamma",3,false}, {"grade_offset",3,false},
    {"grade_contrast",1,false}, {"grade_saturation",1,false}, {"sharpness",1,false}
};
constexpr PipUniform pip_window[] = {
    {"pip_center",2,false}, {"pip_span",2,false}, {"pip_forward",3,false},
    {"pip_right",3,false}, {"pip_up",3,false}, {"pip_tangent",2,false}, {"pip_viewing_eye",1,true}
};
struct PipProgram {
    GLuint program = 0;
    std::array<GLint, 28> common{};
    std::array<GLint, 7> window{};
    GLint origin = -1, size = -1, eye = -1, raw = -1, whole = -1, span = -1, pip = -1;
    GLint make_map = -1, cached = -1;
};
PipProgram pip_programs[2];
GLuint pip_sampler = 0, pip_framebuffer = 0;
struct PipProjection {
    GLuint texture = 0;
    EGLContext context = EGL_NO_CONTEXT;
    std::array<float,6> key{};
    bool valid = false;
    bool failed = false;
} pip_projection;
void release_pip_projection() {
    pip_projection.valid=false; pip_projection.failed=false;
    if (pip_projection.context==eglGetCurrentContext() && pip_projection.texture) {
        glDeleteTextures(1,&pip_projection.texture); pip_projection.texture=0;
    }
}
uint64_t pip_renders = 0, pip_cpu_us = 0;
uint64_t main_cpu_us = 0;
int pip_draws = 0;
bool pip_sample_requested = false;
std::vector<int> pip_sample_pixels;
bool main_sample_requested = false;
std::vector<int> main_sample_pixels;
struct PipTimer {
    struct Query { GLuint id=0; bool pending=false, valid=true; };
    std::array<Query,8> queries{};
    std::array<uint64_t,120> samples{};
    size_t sample_count=0, cursor=0;
    EGLContext context=EGL_NO_CONTEXT;
    PFNGLGETQUERYOBJECTUI64VEXTPROC result=nullptr;
    PFNGLGENQUERIESEXTPROC gen=nullptr;
    PFNGLBEGINQUERYEXTPROC begin_query=nullptr;
    PFNGLENDQUERYEXTPROC end_query=nullptr;
    PFNGLGETQUERYIVEXTPROC query_info=nullptr;
    PFNGLGETQUERYOBJECTUIVEXTPROC query_value=nullptr;
    bool running=false;
    void collect() {
        if (context!=eglGetCurrentContext()) {
            queries={}; samples={}; sample_count=cursor=0; running=false; context=eglGetCurrentContext(); result=nullptr;
            GLint count=0; glGetIntegerv(GL_NUM_EXTENSIONS,&count);
            for(GLint i=0;i<count;++i) {
                const char* name=reinterpret_cast<const char*>(glGetStringi(GL_EXTENSIONS,static_cast<GLuint>(i)));
                if (name && std::strcmp(name,"GL_EXT_disjoint_timer_query")==0)
                    result=reinterpret_cast<PFNGLGETQUERYOBJECTUI64VEXTPROC>(eglGetProcAddress("glGetQueryObjectui64vEXT"));
            }
            gen=reinterpret_cast<PFNGLGENQUERIESEXTPROC>(eglGetProcAddress("glGenQueriesEXT"));
            begin_query=reinterpret_cast<PFNGLBEGINQUERYEXTPROC>(eglGetProcAddress("glBeginQueryEXT"));
            end_query=reinterpret_cast<PFNGLENDQUERYEXTPROC>(eglGetProcAddress("glEndQueryEXT"));
            query_info=reinterpret_cast<PFNGLGETQUERYIVEXTPROC>(eglGetProcAddress("glGetQueryivEXT"));
            query_value=reinterpret_cast<PFNGLGETQUERYOBJECTUIVEXTPROC>(eglGetProcAddress("glGetQueryObjectuivEXT"));
            if (!gen || !begin_query || !end_query || !query_info || !query_value) result=nullptr;
        }
        if (!result) return;
        GLint disjoint=0; glGetIntegerv(GL_GPU_DISJOINT_EXT,&disjoint);
        if (disjoint) { sample_count=0; for(auto& q:queries) if (q.pending) q.valid=false; }
        for(auto& q:queries) if (q.pending) {
            GLuint ready=0; query_value(q.id,GL_QUERY_RESULT_AVAILABLE_EXT,&ready);
            if (!ready) continue;
            GLuint64 elapsed=0; result(q.id,GL_QUERY_RESULT,&elapsed); q.pending=false;
            if (!disjoint && q.valid) { samples[sample_count%samples.size()]=elapsed/1000; ++sample_count; }
        }
    }
    void begin() {
        collect(); if (!result) return;
        GLint current=0; query_info(GL_TIME_ELAPSED_EXT,GL_CURRENT_QUERY_EXT,&current);
        if (current) return; // never nest in a profiler's timer
        for(size_t i=0;i<queries.size();++i) {
            cursor=(cursor+1)%queries.size(); auto& q=queries[cursor];
            if (q.pending) continue;
            if (!q.id) gen(1,&q.id);
            begin_query(GL_TIME_ELAPSED_EXT,q.id); q.valid=true; running=true; return;
        }
    }
    void restart_samples() {
        collect(); samples={}; sample_count=0;
        for(auto& q:queries) if(q.pending) q.valid=false;
    }
    void end() {
        if (!running) return;
        end_query(GL_TIME_ELAPSED_EXT); queries[cursor].pending=true; running=false;
    }
    uint64_t p95() const {
        const size_t count=std::min(sample_count,samples.size());
        if (!count) return 0;
        auto sorted=samples; std::sort(sorted.begin(),sorted.begin()+count);
        return sorted[std::min(count-1,(count*95)/100)];
    }
} pip_timer, main_timer;
std::array<float,47> main_timing_key{};
EGLContext main_timing_context=EGL_NO_CONTEXT;

PipProgram* pip_program(bool external) {
    auto& p = pip_programs[external ? 1 : 0];
    if (p.program && glIsProgram(p.program)) return &p;
    p = PipProgram{};
    constexpr const char* vertex = "#version 300 es\nvoid main() { vec2 p=vec2(float((gl_VertexID<<1)&2),float(gl_VertexID&2)); gl_Position=vec4(p*2.0-1.0,0.0,1.0); }\n";
    const GLuint vs = compile(GL_VERTEX_SHADER, vertex);
    const GLuint fs = compile(GL_FRAGMENT_SHADER, external ? video_rvm_pair_oes_atlas : video_rvm_pair_atlas);
    if (!vs || !fs) { if (vs) glDeleteShader(vs); if (fs) glDeleteShader(fs); return nullptr; }
    p.program = glCreateProgram(); glAttachShader(p.program, vs); glAttachShader(p.program, fs); glLinkProgram(p.program);
    glDeleteShader(vs); glDeleteShader(fs);
    GLint ok = 0; glGetProgramiv(p.program, GL_LINK_STATUS, &ok);
    if (!ok) { log(ANDROID_LOG_WARN, "PiP atlas shader does not link"); glDeleteProgram(p.program); p.program = 0; return nullptr; }
    for (size_t i=0; i<p.common.size(); ++i) p.common[i] = glGetUniformLocation(p.program, pip_common[i].name);
    for (size_t i=0; i<p.window.size(); ++i) p.window[i] = glGetUniformLocation(p.program, pip_window[i].name);
    p.origin=glGetUniformLocation(p.program,"atlas_origin"); p.size=glGetUniformLocation(p.program,"atlas_size");
    p.eye=glGetUniformLocation(p.program,"atlas_eye"); p.raw=glGetUniformLocation(p.program,"atlas_raw");
    p.whole=glGetUniformLocation(p.program,"atlas_main"); p.span=glGetUniformLocation(p.program,"atlas_span");
    p.pip=glGetUniformLocation(p.program,"pip_enabled");
    p.make_map=glGetUniformLocation(p.program,"atlas_make_map"); p.cached=glGetUniformLocation(p.program,"atlas_cached");
    glUseProgram(p.program);
    glUniform1i(glGetUniformLocation(p.program,"color_texture"),0);
    glUniform1i(glGetUniformLocation(p.program,"alpha_texture"),1);
    glUniform1i(glGetUniformLocation(p.program,"atlas_projection"),2);
    glUniform1i(glGetUniformLocation(p.program,"pip_enabled"),1);
    return &p;
}
void pip_uniform(GLint location, const PipUniform& descriptor, const float* v) {
    if (location < 0) return;
    if (descriptor.integer) glUniform1i(location, static_cast<GLint>(v[0]));
    else if (descriptor.components == 1) glUniform1f(location,v[0]);
    else if (descriptor.components == 2) glUniform2fv(location,1,v);
    else if (descriptor.components == 3) glUniform3fv(location,1,v);
    else glUniform4fv(location,1,v);
}
// A small float UV map is generated once with the production projection itself.
// Cache only the smooth 180..240-degree domain; other lenses use the analytic path.
bool prepare_pip_projection(PipProgram& program, const std::array<float,43>& v, GLuint destination) {
    if (v[0]!=2 || v[7]<180 || v[7]>240) return false;
    const EGLContext current=eglGetCurrentContext();
    if (pip_projection.context!=current) { pip_projection=PipProjection{}; pip_projection.context=current; }
    static const bool filterable=[] {
        GLint count=0; glGetIntegerv(GL_NUM_EXTENSIONS,&count);
        for (GLint i=0;i<count;++i) if (std::strcmp(reinterpret_cast<const char*>(glGetStringi(GL_EXTENSIONS,i)),"GL_OES_texture_float_linear")==0) return true;
        return false;
    }();
    if (!filterable) return false;
    const std::array<float,6> key{v[1],v[2],v[3],v[7],v[8],v[9]};
    if (pip_projection.failed && pip_projection.key==key) return false;
    glActiveTexture(GL_TEXTURE2); glBindSampler(2,pip_sampler);
    if (!pip_projection.valid || pip_projection.key!=key) {
        if (!pip_projection.texture) {
            glGenTextures(1,&pip_projection.texture); glBindTexture(GL_TEXTURE_2D,pip_projection.texture);
            glTexStorage2D(GL_TEXTURE_2D,1,GL_RG32F,1025,1025);
        }
        // Do not sample the texture while drawing into it.
        glBindTexture(GL_TEXTURE_2D,0);
        glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,pip_projection.texture,0);
        const bool complete=glCheckFramebufferStatus(GL_DRAW_FRAMEBUFFER)==GL_FRAMEBUFFER_COMPLETE;
        if (complete) {
            glUniform1i(program.make_map,1); glUniform1i(program.cached,0);
            glViewport(0,0,1025,1025); glDrawArrays(GL_TRIANGLES,0,3);
        }
        const bool okay=complete && glGetError()==GL_NO_ERROR;
        while (glGetError()!=GL_NO_ERROR) {}
        glUniform1i(program.make_map,0);
        glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,destination,0);
        pip_projection.valid=okay; pip_projection.key=key; pip_projection.failed=false;
        if (!okay) { release_pip_projection(); pip_projection.failed=true; return false; }
    }
    glBindTexture(GL_TEXTURE_2D,pip_projection.texture);
    return true;
}
} // namespace

/** One source lease, one swapchain, up to six small draws. Rows are fixed slot IDs;
 * each eye has a duplicated two-pixel gutter. No readback, frame delay or new decoder. */
extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_VideoLayerNative_renderPip(JNIEnv* env, jclass, jint slot, jint color, jboolean external,
        jint mask, jint active, jint eyes, jfloatArray common, jfloatArray windows) {
    std::lock_guard<std::mutex> lock(mutex);
    Picture* target = picture(slot);
    if (!target || !target->acquired || color <= 0 || !glIsTexture(static_cast<GLuint>(color)) ||
        active <= 0 || active > 8 || (eyes != 1 && eyes != 2) || !common || !windows ||
        env->GetArrayLength(common) != 43 || env->GetArrayLength(windows) != 48) return JNI_FALSE;
    std::array<float,43> v{}; std::array<float,48> w{};
    env->GetFloatArrayRegion(common,0,43,v.data()); env->GetFloatArrayRegion(windows,0,48,w.data());
    for (float f:v) if (!std::isfinite(f)) return JNI_FALSE;
    for (float f:w) if (!std::isfinite(f)) return JNI_FALSE;
    if ((v[14] != 0 || v[15] != 0) && (mask <= 0 || !glIsTexture(static_cast<GLuint>(mask)))) return JNI_FALSE;
    auto& image = *target;
    const bool whole=active==8; // whole processed main frame, side-by-side output, no tile gutters
    if ((!whole && (eyes != 1 || image.height % 3)) || image.width % eyes || image.width < 40 || image.height < 60) return JNI_FALSE;
    const int width=whole ? image.width/eyes : image.width-4, height=whole ? image.height : image.height/3-4;
    const auto started=std::chrono::steady_clock::now();
    while (glGetError()!=GL_NO_ERROR) {}
    GLenum status=GL_FRAMEBUFFER_COMPLETE;
    {
        DrawState saved;
        GLint previous_external=0; glActiveTexture(GL_TEXTURE0);
        const GLenum kind=external==JNI_TRUE ? GL_TEXTURE_EXTERNAL_OES : GL_TEXTURE_2D;
        if (external==JNI_TRUE) glGetIntegerv(GL_TEXTURE_BINDING_EXTERNAL_OES,&previous_external);
        PipProgram* program=pip_program(external==JNI_TRUE);
        if (!program) return JNI_FALSE;
        if (!pip_sampler || !glIsSampler(pip_sampler)) {
            glGenSamplers(1,&pip_sampler); glSamplerParameteri(pip_sampler,GL_TEXTURE_MIN_FILTER,GL_LINEAR);
            glSamplerParameteri(pip_sampler,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
            glSamplerParameteri(pip_sampler,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);
            glSamplerParameteri(pip_sampler,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);
        }
        if (!pip_framebuffer || !glIsFramebuffer(pip_framebuffer)) glGenFramebuffers(1,&pip_framebuffer);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER,pip_framebuffer);
        glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,image.acquired,0);
        status=glCheckFramebufferStatus(GL_DRAW_FRAMEBUFFER);
        if (status==GL_FRAMEBUFFER_COMPLETE) {
            glDisable(GL_BLEND); glDisable(GL_SCISSOR_TEST); glDisable(GL_DEPTH_TEST); glDisable(GL_CULL_FACE);
            glDisable(GL_STENCIL_TEST); glDisable(GL_DITHER); glColorMask(GL_TRUE,GL_TRUE,GL_TRUE,GL_TRUE);
            glBindVertexArray(0); glUseProgram(program->program);
            glActiveTexture(GL_TEXTURE0); glBindTexture(kind,static_cast<GLuint>(color)); glBindSampler(0,pip_sampler);
            glActiveTexture(GL_TEXTURE1); glBindTexture(GL_TEXTURE_2D,static_cast<GLuint>(mask)); glBindSampler(1,pip_sampler);
            // Transparent output needs linear premultiplication; let the sRGB
            // attachment encode it in hardware instead of three shader pow()s.
            // Opaque output keeps the direct encoded-byte fast path.
            const bool raw=DrawState::srgb_control() && v[14]==0 && v[26]==0;
            if (raw) glDisable(DrawState::kFramebufferSrgb);
            glUniform1i(program->raw,raw ? 1 : 0); glUniform2f(program->size,static_cast<float>(width),static_cast<float>(height));
            glUniform1i(program->whole,whole ? 1 : 0); glUniform1i(program->pip,whole ? 0 : 1);
            glUniform1i(program->make_map,0); glUniform1i(program->cached,0);
            constexpr float pi=3.14159265358979323846f;
            const float span=v[0]==3 ? 2*pi : v[0]==1 ? pi : v[7]*pi/180.0f;
            glUniform2f(program->span,span,v[0]==2 ? std::min(span,pi) : pi);
            size_t offset=0;
            for(size_t i=0;i<program->common.size();++i) { pip_uniform(program->common[i],pip_common[i],v.data()+offset); offset+=pip_common[i].components; }
            if (whole) glUniform1i(program->cached,prepare_pip_projection(*program,v,image.acquired) ? 1 : 0);
            int draws=0;
            auto& timer=whole ? main_timer : pip_timer;
            if (whole) {
                std::array<float,47> key{};
                std::copy(v.begin(),v.end(),key.begin());
                key[43]=image.width; key[44]=image.height; key[45]=eyes; key[46]=external==JNI_TRUE ? 1.0f : 0.0f;
                if (key!=main_timing_key || main_timing_context!=eglGetCurrentContext()) {
                    main_timer.restart_samples(); main_timing_key=key; main_timing_context=eglGetCurrentContext();
                }
            }
            timer.begin();
            for(int index=0;index<(whole ? 1 : 3);++index) if (whole || (active & (1<<index))) {
                offset=static_cast<size_t>(index)*16;
                for(size_t i=0;i<program->window.size();++i) { pip_uniform(program->window[i],pip_window[i],w.data()+offset); offset+=pip_window[i].components; }
                for(int eye=0;eye<eyes;++eye) {
                    const int gutter=whole ? 0 : 4;
                    const int x=eye*(width+gutter),y=index*(height+gutter);
                    glViewport(x,y,width+gutter,height+gutter); glUniform2f(program->origin,static_cast<float>(x),static_cast<float>(y));
                    glUniform1i(program->eye,eye); glDrawArrays(GL_TRIANGLES,0,3); ++draws;
                }
            }
            timer.end();
            if (!whole) pip_draws=draws;
            if ((pip_sample_requested && !whole) || (main_sample_requested && whole)) {
                auto& pixels=whole ? main_sample_pixels : pip_sample_pixels;
                if (whole) main_sample_requested=false; else pip_sample_requested=false;
                pixels.clear();
                GLint read=0, pack=0, row=0, skip_rows=0, skip_pixels=0;
                glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING,&read); glGetIntegerv(GL_PIXEL_PACK_BUFFER_BINDING,&pack);
                glGetIntegerv(GL_PACK_ROW_LENGTH,&row); glGetIntegerv(GL_PACK_SKIP_ROWS,&skip_rows); glGetIntegerv(GL_PACK_SKIP_PIXELS,&skip_pixels);
                glBindFramebuffer(GL_READ_FRAMEBUFFER,pip_framebuffer); glBindBuffer(GL_PIXEL_PACK_BUFFER,0);
                glPixelStorei(GL_PACK_ROW_LENGTH,0); glPixelStorei(GL_PACK_SKIP_ROWS,0); glPixelStorei(GL_PACK_SKIP_PIXELS,0);
                for(int index=0;index<(whole ? 1 : 3);++index) if (whole || (active & (1<<index))) for(int eye=0;eye<eyes;++eye) {
                    std::array<uint8_t,4> rgba{};
                    const int gutter=whole ? 0 : 4, inset=whole ? 0 : 2;
                    glReadPixels(eye*(width+gutter)+inset+width/2,index*(height+gutter)+inset+height/2,1,1,GL_RGBA,GL_UNSIGNED_BYTE,rgba.data());
                    pixels.push_back(whole ? 0 : index+1); pixels.push_back(eye);
                    for(uint8_t channel:rgba) pixels.push_back(channel);
                }
                glPixelStorei(GL_PACK_ROW_LENGTH,row); glPixelStorei(GL_PACK_SKIP_ROWS,skip_rows); glPixelStorei(GL_PACK_SKIP_PIXELS,skip_pixels);
                glBindBuffer(GL_PIXEL_PACK_BUFFER,static_cast<GLuint>(pack)); glBindFramebuffer(GL_READ_FRAMEBUFFER,static_cast<GLuint>(read));
            }
        }
        if (external==JNI_TRUE) { glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_EXTERNAL_OES,static_cast<GLuint>(previous_external)); }
    }
    const GLenum error=glGetError();
    const auto cpu=static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now()-started).count());
    if (whole) main_cpu_us=cpu; else pip_cpu_us=cpu;
    if (status!=GL_FRAMEBUFFER_COMPLETE || error!=GL_NO_ERROR) {
        log(ANDROID_LOG_WARN,"PiP atlas draw failed: framebuffer "+std::to_string(status)+" GL "+std::to_string(error)); return JNI_FALSE;
    }
    if (!whole) ++pip_renders;
    return JNI_TRUE;
}

extern "C" JNIEXPORT jstring JNICALL
Java_org_vrpassthroughplayer_plugin_VideoLayerNative_pipMetrics(JNIEnv* env, jclass) {
    std::lock_guard<std::mutex> lock(mutex);
    // Only read query results that are already ready; never wait for the GPU.
    pip_timer.collect(); main_timer.collect();
    return env->NewStringUTF((std::to_string(pip_cpu_us)+" "+std::to_string(pip_timer.p95())+" "+
        std::to_string(pip_timer.sample_count)+" "+std::to_string(pip_renders)+" "+std::to_string(pip_draws)+" "+
        std::to_string(main_timer.p95())+" "+std::to_string(main_timer.sample_count)+" "+std::to_string(main_cpu_us)+" "+
        std::to_string(pip_projection.valid ? 1 : 0)).c_str());
}

extern "C" JNIEXPORT jstring JNICALL
Java_org_vrpassthroughplayer_plugin_VideoLayerNative_pipSamples(JNIEnv* env, jclass, jboolean request) {
    std::lock_guard<std::mutex> lock(mutex);
    if (request==JNI_TRUE) { pip_sample_requested=true; pip_sample_pixels.clear(); }
    std::string pixels;
    for(int value:pip_sample_pixels) { if (!pixels.empty()) pixels+=' '; pixels+=std::to_string(value); }
    return env->NewStringUTF(pixels.c_str());
}

extern "C" JNIEXPORT jstring JNICALL
Java_org_vrpassthroughplayer_plugin_VideoLayerNative_pipMainSamples(JNIEnv* env, jclass, jboolean request) {
    std::lock_guard<std::mutex> lock(mutex);
    if (request==JNI_TRUE) { main_sample_requested=true; main_sample_pixels.clear(); }
    std::string pixels;
    for(int value:main_sample_pixels) { if (!pixels.empty()) pixels+=' '; pixels+=std::to_string(value); }
    return env->NewStringUTF(pixels.c_str());
}

/** Fisheye -> equirect for the equirect picture layer (no layer shape exists for a lens). Each view keeps
 * its place in the frame (layout 0 mono, 1 side by side, 2 top-bottom); one view spans span.x radians
 * across and span.y high. Same lens mapping as video_coordinates.gdshaderinc (equidistant, padded
 * circle, or the whole eye rectangle for half-width stereo); outside the lens is black. */
GLuint fisheye_programs[2] = {0, 0};
GLuint fisheye_sampler = 0;
/** Debug only: the next remap reads its picture back, every [step]th pixel, as RGBA8 rows top-first. */
int fisheye_readback_step = 0;
std::vector<uint8_t> fisheye_readback;
int fisheye_readback_size[2] = {0, 0};
GLuint fisheye_program(bool external) {
    GLuint& program = fisheye_programs[external ? 1 : 0];
    if (program && glIsProgram(program)) return program;
    static const char* vertex = "#version 300 es\n"
        "void main() { vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2)); gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0); }\n";
    const std::string fragment = std::string("#version 300 es\n") +
        (external ? "#extension GL_OES_EGL_image_external_essl3 : require\n" : "") +
        "precision highp float;\n" +
        (external ? "uniform samplerExternalOES source;\n" : "uniform sampler2D source;\n") +
        "uniform vec2 target; uniform vec2 source_size; uniform vec2 span; uniform vec2 uv_scale;\n"
        "uniform float fov; uniform int frame_layout; uniform int half_eyes; uniform int raw_output;\n"
        "out vec4 result;\n"
        "vec3 to_linear(vec3 c) { return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c)); }\n"
        "void main() {\n"
        "  vec2 uv = gl_FragCoord.xy / target; // row 0 is the picture's top, as for every GL picture here\n"
        "  float eye = 0.0; vec2 local = uv;\n"
        "  if (frame_layout == 1) { eye = step(0.5, uv.x); local.x = uv.x * 2.0 - eye; }\n"
        "  else if (frame_layout == 2) { eye = step(0.5, uv.y); local.y = uv.y * 2.0 - eye; }\n"
        "  float longitude = (local.x - 0.5) * span.x; float latitude = (0.5 - local.y) * span.y;\n"
        "  vec3 d = vec3(cos(latitude) * sin(longitude), sin(latitude), -cos(latitude) * cos(longitude));\n"
        "  float radial = acos(clamp(-d.z, -1.0, 1.0)) / radians(fov * 0.5);\n"
        "  if (radial > 1.0) { result = vec4(0.0, 0.0, 0.0, 1.0); return; }\n"
        "  float transverse = length(d.xy);\n"
        "  vec2 axis = transverse > 0.000001 ? vec2(d.x, -d.y) / transverse : vec2(0.0);\n"
        "  vec2 eye_size = vec2(source_size.x * (frame_layout == 1 ? 0.5 : 1.0), source_size.y * (frame_layout == 2 ? 0.5 : 1.0));\n"
        "  vec2 p = half_eyes == 1 ? vec2(0.5) + 0.5 * radial * axis : vec2(0.5) + 0.5 * radial * axis * min(eye_size.x, eye_size.y) / eye_size;\n"
        "  p = clamp(p, vec2(0.5) / eye_size, vec2(1.0) - vec2(0.5) / eye_size);\n"
        "  if (frame_layout == 1) { p.x = (p.x + eye) * 0.5; } else if (frame_layout == 2) { p.y = (p.y + eye) * 0.5; }\n"
        "  vec3 c = texture(source, p * uv_scale).rgb;\n"
        "  result = vec4(raw_output == 1 ? c : to_linear(c), 1.0);\n"
        "}\n";
    const GLuint vs = compile(GL_VERTEX_SHADER, vertex), fs = compile(GL_FRAGMENT_SHADER, fragment.c_str());
    if (!vs || !fs) { if (vs) glDeleteShader(vs); if (fs) glDeleteShader(fs); return 0; }
    program = glCreateProgram();
    glAttachShader(program, vs); glAttachShader(program, fs); glLinkProgram(program);
    glDeleteShader(vs); glDeleteShader(fs);
    GLint ok = 0; glGetProgramiv(program, GL_LINK_STATUS, &ok);
    if (!ok) { log(ANDROID_LOG_WARN, "fisheye program does not link"); glDeleteProgram(program); program = 0; }
    return program;
}

/** Draws the fisheye frame [texture] (GL_TEXTURE_2D, or the decoder's external image) remapped into the
 * whole acquired image of [slot]. params: layout, half_eyes, fov degrees, span x, span y (radians),
 * source width, source height, UV scale x, UV scale y. */
extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_VideoLayerNative_remapFisheye(JNIEnv* env, jclass, jint slot, jint texture, jboolean external, jfloatArray params) {
    std::lock_guard<std::mutex> lock(mutex);
    Picture* target = picture(slot);
    if (!target || !params || env->GetArrayLength(params) < 9) return JNI_FALSE;
    Picture& p = *target;
    if (!p.acquired || texture <= 0 || !glIsTexture(static_cast<GLuint>(texture))) {
        log(ANDROID_LOG_WARN, "remapFisheye: texture " + std::to_string(texture) + " not usable (acquired " + std::to_string(p.acquired) + ")");
        return JNI_FALSE;
    }
    float v[9] = {};
    env->GetFloatArrayRegion(params, 0, 9, v);
    const GLenum kind = external == JNI_TRUE ? GL_TEXTURE_EXTERNAL_OES : GL_TEXTURE_2D;
    while (glGetError() != GL_NO_ERROR) {}
    GLenum status = GL_FRAMEBUFFER_COMPLETE;
    {
        DrawState saved;
        GLint previous_external = 0;
        glActiveTexture(GL_TEXTURE0);
        if (kind == GL_TEXTURE_EXTERNAL_OES) glGetIntegerv(GL_TEXTURE_BINDING_EXTERNAL_OES, &previous_external);
        const GLuint program = fisheye_program(kind == GL_TEXTURE_EXTERNAL_OES);
        if (!program) return JNI_FALSE;
        if (!fisheye_sampler || !glIsSampler(fisheye_sampler)) {
            glGenSamplers(1, &fisheye_sampler);
            glSamplerParameteri(fisheye_sampler, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
            glSamplerParameteri(fisheye_sampler, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
            glSamplerParameteri(fisheye_sampler, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
            glSamplerParameteri(fisheye_sampler, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        }
        GLuint framebuffer = 0;
        glGenFramebuffers(1, &framebuffer);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, framebuffer);
        glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, p.acquired, 0);
        status = glCheckFramebufferStatus(GL_DRAW_FRAMEBUFFER);
        if (status == GL_FRAMEBUFFER_COMPLETE) {
            glDisable(GL_BLEND); glDisable(GL_SCISSOR_TEST); glDisable(GL_DEPTH_TEST);
            glDisable(GL_CULL_FACE); glDisable(GL_STENCIL_TEST); glDisable(GL_DITHER);
            glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
            glViewport(0, 0, p.width, p.height);
            glUseProgram(program);
            glBindVertexArray(0);
            glBindTexture(kind, static_cast<GLuint>(texture)); glBindSampler(0, fisheye_sampler);
            glUniform1i(glGetUniformLocation(program, "source"), 0);
            glUniform2f(glGetUniformLocation(program, "target"), static_cast<float>(p.width), static_cast<float>(p.height));
            glUniform1i(glGetUniformLocation(program, "frame_layout"), static_cast<int>(v[0]));
            glUniform1i(glGetUniformLocation(program, "half_eyes"), static_cast<int>(v[1]));
            glUniform1f(glGetUniformLocation(program, "fov"), v[2]);
            glUniform2f(glGetUniformLocation(program, "span"), v[3], v[4]);
            glUniform2f(glGetUniformLocation(program, "source_size"), v[5], v[6]);
            glUniform2f(glGetUniformLocation(program, "uv_scale"), v[7], v[8]);
            // Without sRGB write encoding the frame's encoded values go in as they are (as copyTexture
            // copies them), saving a per-pixel decode and the hardware re-encode.
            const bool raw = DrawState::srgb_control();
            if (raw) glDisable(DrawState::kFramebufferSrgb);
            glUniform1i(glGetUniformLocation(program, "raw_output"), raw ? 1 : 0);
            glDrawArrays(GL_TRIANGLES, 0, 3);
            if (fisheye_readback_step > 0) {
                const int step = fisheye_readback_step; fisheye_readback_step = 0;
                std::vector<uint8_t> full(static_cast<size_t>(p.width) * p.height * 4);
                GLint read_framebuffer = 0; glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &read_framebuffer);
                glBindFramebuffer(GL_READ_FRAMEBUFFER, framebuffer);
                glPixelStorei(GL_PACK_ALIGNMENT, 1);
                glReadPixels(0, 0, p.width, p.height, GL_RGBA, GL_UNSIGNED_BYTE, full.data());
                glBindFramebuffer(GL_READ_FRAMEBUFFER, static_cast<GLuint>(read_framebuffer));
                const int w = p.width / step, h = p.height / step;
                fisheye_readback.assign(static_cast<size_t>(w) * h * 4, 0);
                for (int y = 0; y < h; ++y) for (int x = 0; x < w; ++x)
                    std::memcpy(&fisheye_readback[(static_cast<size_t>(y) * w + x) * 4], &full[(static_cast<size_t>(y * step) * p.width + x * step) * 4], 4);
                fisheye_readback_size[0] = w; fisheye_readback_size[1] = h;
            }
        }
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0);
        glDeleteFramebuffers(1, &framebuffer);
        if (kind == GL_TEXTURE_EXTERNAL_OES) glBindTexture(GL_TEXTURE_EXTERNAL_OES, static_cast<GLuint>(previous_external));
    }
    const GLenum error = glGetError();
    if (status != GL_FRAMEBUFFER_COMPLETE || error != GL_NO_ERROR)
        log(ANDROID_LOG_WARN, "remapFisheye framebuffer status " + std::to_string(status) + " GL error " + std::to_string(error));
    return status == GL_FRAMEBUFFER_COMPLETE && error == GL_NO_ERROR ? JNI_TRUE : JNI_FALSE;
}

/** Debug only: arms a readback of the next fisheye remap (every [step]th pixel). */
extern "C" JNIEXPORT void JNICALL
Java_org_vrpassthroughplayer_plugin_VideoLayerNative_requestFisheyeReadback(JNIEnv*, jclass, jint step) {
    std::lock_guard<std::mutex> lock(mutex);
    fisheye_readback_step = step > 0 ? step : 0; fisheye_readback.clear();
}
/** Debug only: width, height, then RGBA8 rows top-first; empty until a remap read back. */
extern "C" JNIEXPORT jbyteArray JNICALL
Java_org_vrpassthroughplayer_plugin_VideoLayerNative_takeFisheyeReadback(JNIEnv* env, jclass) {
    std::lock_guard<std::mutex> lock(mutex);
    if (fisheye_readback.empty()) return env->NewByteArray(0);
    std::vector<uint8_t> out(8 + fisheye_readback.size());
    for (int i = 0; i < 2; ++i) { const uint32_t v = static_cast<uint32_t>(fisheye_readback_size[i]); std::memcpy(&out[i * 4], &v, 4); }
    std::memcpy(&out[8], fisheye_readback.data(), fisheye_readback.size());
    fisheye_readback.clear();
    jbyteArray result = env->NewByteArray(static_cast<jsize>(out.size()));
    env->SetByteArrayRegion(result, 0, static_cast<jsize>(out.size()), reinterpret_cast<const jbyte*>(out.data()));
    return result;
}

/** Rows [y, y + rows) of the acquired image from an RGBA8 colour band and an R8 mask band of the same
 * size (Godot textures), drawn as premultiplied colour x soft mask: the portrait cutout of a photo. */
extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_VideoLayerNative_copyBandMasked(JNIEnv*, jclass, jint slot, jint color, jint mask, jint y, jint rows) {
    std::lock_guard<std::mutex> lock(mutex);
    Picture* target = picture(slot);
    if (!target) return JNI_FALSE;
    Picture& p = *target;
    if (!p.acquired || color <= 0 || mask <= 0 || y < 0 || rows <= 0 || y + rows > p.height
        || !glIsTexture(static_cast<GLuint>(color)) || !glIsTexture(static_cast<GLuint>(mask))) return JNI_FALSE;
    while (glGetError() != GL_NO_ERROR) {}
    GLenum status = GL_FRAMEBUFFER_COMPLETE;
    {
        DrawState saved;
        const GLuint program = masked_copy_program();
        if (!program) return JNI_FALSE;
        GLuint framebuffer = 0;
        glGenFramebuffers(1, &framebuffer);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, framebuffer);
        glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, p.acquired, 0);
        status = glCheckFramebufferStatus(GL_DRAW_FRAMEBUFFER);
        if (status == GL_FRAMEBUFFER_COMPLETE) {
            glDisable(GL_BLEND); glDisable(GL_SCISSOR_TEST); glDisable(GL_DEPTH_TEST);
            glDisable(GL_CULL_FACE); glDisable(GL_STENCIL_TEST); glDisable(GL_DITHER);
            glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
            glViewport(0, y, p.width, rows);
            glUseProgram(program);
            glBindVertexArray(0);
            glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, static_cast<GLuint>(color)); glBindSampler(0, 0);
            glActiveTexture(GL_TEXTURE1); glBindTexture(GL_TEXTURE_2D, static_cast<GLuint>(mask)); glBindSampler(1, 0);
            glUniform1i(glGetUniformLocation(program, "color_band"), 0);
            glUniform1i(glGetUniformLocation(program, "mask_band"), 1);
            glUniform1i(glGetUniformLocation(program, "first_row"), y);
            glDrawArrays(GL_TRIANGLES, 0, 3);
        }
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0);
        glDeleteFramebuffers(1, &framebuffer);
    }
    const GLenum error = glGetError();
    if (status != GL_FRAMEBUFFER_COMPLETE || error != GL_NO_ERROR)
        log(ANDROID_LOG_WARN, "copyBandMasked framebuffer status " + std::to_string(status) + " GL error " + std::to_string(error));
    return status == GL_FRAMEBUFFER_COMPLETE && error == GL_NO_ERROR ? JNI_TRUE : JNI_FALSE;
}

/** Alpha plan B: draws RVM's mask texture (R8, 2 x model width: left | right) into the whole acquired
 * image of [slot] laid out as the video frame (0 mono, 1 side by side, 2 top-bottom); rect maps eye UV
 * to model UV (the pair's model_content_rect). */
extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_VideoLayerNative_drawMask(JNIEnv* env, jclass, jint slot, jint mask, jfloatArray rect,
        jint frame_layout, jint model_width, jint model_height, jfloat edge_low, jfloat edge_high) {
    std::lock_guard<std::mutex> lock(mutex);
    Picture* target = picture(slot);
    if (!target || !target->acquired || mask <= 0 || !rect || env->GetArrayLength(rect) != 4 || model_width <= 0 || model_height <= 0
        || !glIsTexture(static_cast<GLuint>(mask))) return JNI_FALSE;
    std::array<float, 4> window{}; env->GetFloatArrayRegion(rect, 0, 4, window.data());
    for (float value : window) if (!std::isfinite(value)) return JNI_FALSE;
    Picture& p = *target;
    while (glGetError() != GL_NO_ERROR) {}
    GLenum status = GL_FRAMEBUFFER_COMPLETE;
    {
        DrawState saved;
        const GLuint program = mask_draw_program();
        if (!program) return JNI_FALSE;
        GLuint framebuffer = 0;
        glGenFramebuffers(1, &framebuffer);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, framebuffer);
        glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, p.acquired, 0);
        status = glCheckFramebufferStatus(GL_DRAW_FRAMEBUFFER);
        if (status == GL_FRAMEBUFFER_COMPLETE) {
            glDisable(GL_BLEND); glDisable(GL_SCISSOR_TEST); glDisable(GL_DEPTH_TEST);
            glDisable(GL_CULL_FACE); glDisable(GL_STENCIL_TEST); glDisable(GL_DITHER);
            glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
            glViewport(0, 0, p.width, p.height);
            glUseProgram(program);
            glBindVertexArray(0);
            glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, static_cast<GLuint>(mask)); glBindSampler(0, 0);
            glUniform1i(glGetUniformLocation(program, "mask"), 0);
            glUniform4f(glGetUniformLocation(program, "rect"), window[0], window[1], window[2], window[3]);
            glUniform1i(glGetUniformLocation(program, "frame_layout"), frame_layout);
            glUniform2f(glGetUniformLocation(program, "model_size"), static_cast<float>(model_width), static_cast<float>(model_height));
            glUniform2f(glGetUniformLocation(program, "target"), static_cast<float>(p.width), static_cast<float>(p.height));
            glUniform2f(glGetUniformLocation(program, "edge"), std::isfinite(edge_low) ? edge_low : 0.0f, std::isfinite(edge_high) ? edge_high : 1.0f);
            glDrawArrays(GL_TRIANGLES, 0, 3);
        }
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0);
        glDeleteFramebuffers(1, &framebuffer);
    }
    const GLenum error = glGetError();
    if (status != GL_FRAMEBUFFER_COMPLETE || error != GL_NO_ERROR) {
        log(ANDROID_LOG_WARN, "drawMask framebuffer status " + std::to_string(status) + " GL error " + std::to_string(error));
        return JNI_FALSE;
    }
    return JNI_TRUE;
}

/** Counts a mask released into the mask swapchain; Godot reads it with maskVersion(). */
extern "C" JNIEXPORT jlong JNICALL
Java_org_vrpassthroughplayer_plugin_VideoLayerNative_maskDrawn(JNIEnv*, jclass) {
    std::lock_guard<std::mutex> lock(mutex);
    return static_cast<jlong>(++mask_version);
}
extern "C" JNIEXPORT jlong JNICALL
Java_org_vrpassthroughplayer_plugin_VideoLayerNative_maskVersion(JNIEnv*, jclass) {
    std::lock_guard<std::mutex> lock(mutex);
    return static_cast<jlong>(mask_version);
}
