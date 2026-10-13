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
#include <chrono>
#include <cmath>
#include <cstring>
#include <mutex>
#include <stdexcept>
#include <string>
#define XR_USE_PLATFORM_ANDROID
#include <EGL/egl.h>
#include <GLES3/gl32.h>
#include <vector>
#define XR_USE_GRAPHICS_API_OPENGL_ES
#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>
#include "layer_layout.h"

namespace {
constexpr int kMaxLayers = 2;
constexpr int kStride = 20; // floats per layer in setLayers()
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
    std::array<Layer, kMaxLayers> layers{};
    // Next-chain structs of each layer (XR_FB extensions Godot's vendors plugin enables on Meta runtimes).
    std::array<XrCompositionLayerImageLayoutFB, kMaxLayers> layouts{};
    std::array<XrCompositionLayerSettingsFB, kMaxLayers> settings{};
    std::array<uint64_t, kMaxLayers> logged_layout{};
    int count = 0;
    // RGBA picture swapchain (2D->3D pairs, photos).
    PFN_xrCreateSwapchain create_swapchain = nullptr;
    PFN_xrEnumerateSwapchainImages enumerate_images = nullptr;
    PFN_xrAcquireSwapchainImage acquire_image = nullptr;
    PFN_xrWaitSwapchainImage wait_image = nullptr;
    PFN_xrReleaseSwapchainImage release_image = nullptr;
    XrSwapchain image = XR_NULL_HANDLE;
    std::vector<GLuint> image_textures;
    int image_width = 0, image_height = 0, image_levels = 0;
    bool image_static = false;
    GLuint acquired = 0; // texture of the acquired image, 0 when none
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
void destroy_image() {
    if (state.image != XR_NULL_HANDLE) {
        if (state.acquired && state.release_image) {
            XrSwapchainImageReleaseInfo info{}; info.type = XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO;
            state.release_image(state.image, &info);
        }
        if (state.destroy_swapchain) state.destroy_swapchain(state.image);
    }
    state.image = XR_NULL_HANDLE; state.image_textures.clear(); state.acquired = 0;
    state.image_width = state.image_height = state.image_levels = 0;
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
        if (state.session != XR_NULL_HANDLE && state.session != new_session) { destroy(env); destroy_image(); }
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
 * enabled. 19: source, 0 the decoder surface, 1 the RGBA picture swapchain. count 0 hides the layers. */
extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_VideoLayerNative_setLayers(JNIEnv* env, jclass, jint count, jfloatArray values) {
    std::lock_guard<std::mutex> lock(mutex);
    if (count < 0 || count > kMaxLayers || !values || env->GetArrayLength(values) < count * kStride) {
        log(ANDROID_LOG_WARN, "setLayers: bad count " + std::to_string(count)); return JNI_FALSE;
    }
    std::array<float, kMaxLayers * kStride> v{};
    env->GetFloatArrayRegion(values, 0, count * kStride, v.data());
    for (int i = 0; i < count * kStride; ++i) if (!std::isfinite(v[i])) {
        log(ANDROID_LOG_WARN, "setLayers: value " + std::to_string(i) + " not finite"); return JNI_FALSE;
    }
    for (int i = 0; i < count; ++i) {
        // A picture layer shows only a released image: never one still being written.
        const bool picture = v[i * kStride + 19] > 0.5f;
        const XrSwapchain source = picture ? state.image : state.swapchain;
        if (source == XR_NULL_HANDLE || (picture && state.acquired)) {
            log(ANDROID_LOG_WARN, std::string("setLayers: ") + (picture ? "picture" : "surface") + " swapchain " +
                (source == XR_NULL_HANDLE ? "missing" : "still acquired"));
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
        sub.swapchain = p[19] > 0.5f ? state.image : state.swapchain;
        sub.imageRect = {{static_cast<int32_t>(std::lround(p[9])), static_cast<int32_t>(std::lround(p[10]))},
                         {static_cast<int32_t>(std::lround(p[11])), static_cast<int32_t>(std::lround(p[12]))}};
        const XrEyeVisibility visibility = eye == 1 ? XR_EYE_VISIBILITY_LEFT : (eye == 2 ? XR_EYE_VISIBILITY_RIGHT : XR_EYE_VISIBILITY_BOTH);
        // Opaque video; the runtime corrects chromatic aberration for the layer as for eye buffers.
        const XrCompositionLayerFlags flags = XR_COMPOSITION_LAYER_CORRECT_CHROMATIC_ABERRATION_BIT;
        const void* next = quest::image_layout_next(state.layouts[i], p[17], nullptr);
        const auto settings_flags = static_cast<XrCompositionLayerSettingsFlagsFB>(std::lround(p[18]));
        if (settings_flags) {
            state.settings[i] = {};
            state.settings[i].type = XR_TYPE_COMPOSITION_LAYER_SETTINGS_FB;
            state.settings[i].next = next;
            state.settings[i].layerFlags = settings_flags;
            next = &state.settings[i];
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
Java_org_vrpassthroughplayer_plugin_VideoLayerNative_createImage(JNIEnv* env, jclass, jint width, jint height, jint levels, jboolean is_static) {
    std::lock_guard<std::mutex> lock(mutex);
    if (!state.create_swapchain || state.session == XR_NULL_HANDLE) { fail(env, "Picture layer is not bound to an OpenXR session"); return JNI_FALSE; }
    if (width <= 0 || height <= 0 || width > 16384 || height > 16384 || levels < 1 || levels > 15) { fail(env, "Picture layer size invalid"); return JNI_FALSE; }
    if (state.image != XR_NULL_HANDLE && state.image_width == width && state.image_height == height &&
        state.image_levels == levels && state.image_static == (is_static == JNI_TRUE) && !state.image_static) return JNI_TRUE;
    // Layers may still name the old picture swapchain: never submit a destroyed handle.
    for (int i = 0; i < state.count; ++i) {
        if (state.image != XR_NULL_HANDLE && state.layers[i].quad.subImage.swapchain == state.image) { state.count = 0; break; }
    }
    destroy_image();
    XrSwapchainCreateInfo info{};
    info.type = XR_TYPE_SWAPCHAIN_CREATE_INFO;
    info.createFlags = is_static == JNI_TRUE ? XR_SWAPCHAIN_CREATE_STATIC_IMAGE_BIT : 0;
    info.usageFlags = XR_SWAPCHAIN_USAGE_SAMPLED_BIT | XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT | XR_SWAPCHAIN_USAGE_TRANSFER_DST_BIT;
    info.format = GL_SRGB8_ALPHA8;
    info.sampleCount = 1; info.faceCount = 1; info.arraySize = 1;
    info.width = static_cast<uint32_t>(width); info.height = static_cast<uint32_t>(height); info.mipCount = static_cast<uint32_t>(levels);
    XrResult result = state.create_swapchain(state.session, &info, &state.image);
    if (XR_FAILED(result)) { fail(env, ("xrCreateSwapchain failed: " + std::to_string(result)).c_str()); state.image = XR_NULL_HANDLE; return JNI_FALSE; }
    uint32_t count = 0;
    state.enumerate_images(state.image, 0, &count, nullptr);
    std::vector<XrSwapchainImageOpenGLESKHR> images(count);
    for (auto& image : images) { image = {}; image.type = XR_TYPE_SWAPCHAIN_IMAGE_OPENGL_ES_KHR; }
    result = state.enumerate_images(state.image, count, &count, reinterpret_cast<XrSwapchainImageBaseHeader*>(images.data()));
    if (XR_FAILED(result) || count == 0) { destroy_image(); fail(env, "Picture swapchain images unavailable"); return JNI_FALSE; }
    for (const auto& image : images) state.image_textures.push_back(image.image);
    state.image_width = width; state.image_height = height; state.image_levels = levels; state.image_static = is_static == JNI_TRUE;
    return JNI_TRUE;
}

extern "C" JNIEXPORT void JNICALL
Java_org_vrpassthroughplayer_plugin_VideoLayerNative_destroyImage(JNIEnv*, jclass) {
    std::lock_guard<std::mutex> lock(mutex);
    for (int i = 0; i < state.count; ++i) {
        if (state.image != XR_NULL_HANDLE && state.layers[i].quad.subImage.swapchain == state.image) { state.count = 0; break; }
    }
    destroy_image();
}

/** Acquires (and waits for) the next picture image; its GL texture name, 0 on failure. */
extern "C" JNIEXPORT jint JNICALL
Java_org_vrpassthroughplayer_plugin_VideoLayerNative_acquireImage(JNIEnv*, jclass) {
    std::lock_guard<std::mutex> lock(mutex);
    if (state.image == XR_NULL_HANDLE || state.acquired) return static_cast<jint>(state.acquired);
    XrSwapchainImageAcquireInfo acquire{}; acquire.type = XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO;
    uint32_t index = 0;
    if (XR_FAILED(state.acquire_image(state.image, &acquire, &index)) || index >= state.image_textures.size()) return 0;
    XrSwapchainImageWaitInfo wait{}; wait.type = XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO; wait.timeout = XR_INFINITE_DURATION;
    if (XR_FAILED(state.wait_image(state.image, &wait))) {
        XrSwapchainImageReleaseInfo release{}; release.type = XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO;
        state.release_image(state.image, &release);
        return 0;
    }
    state.acquired = state.image_textures[index];
    return static_cast<jint>(state.acquired);
}

/** Generates the mip chain of the acquired image (when it has levels) and releases it to the compositor. */
extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_VideoLayerNative_releaseImage(JNIEnv*, jclass, jboolean mipmaps) {
    std::lock_guard<std::mutex> lock(mutex);
    if (!state.acquired) return JNI_FALSE;
    if (mipmaps == JNI_TRUE && state.image_levels > 1) {
        GlState saved;
        glBindTexture(GL_TEXTURE_2D, state.acquired); glGenerateMipmap(GL_TEXTURE_2D);
    }
    XrSwapchainImageReleaseInfo release{}; release.type = XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO;
    const bool ok = XR_SUCCEEDED(state.release_image(state.image, &release));
    state.acquired = 0;
    return ok && glGetError() == GL_NO_ERROR ? JNI_TRUE : JNI_FALSE;
}

/** Rows [y, y + rows) of level 0 of the acquired image from tightly packed RGBA8 (channels 4) or
 * RGB8 (channels 3, expanded here: JPEG photos decode to RGB, a full RGBA copy would double memory). */
extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_VideoLayerNative_uploadRows(JNIEnv* env, jclass, jint y, jint rows, jbyteArray pixels, jint channels) {
    std::lock_guard<std::mutex> lock(mutex);
    if (!state.acquired || !pixels || y < 0 || rows <= 0 || y + rows > state.image_height || (channels != 3 && channels != 4) ||
        env->GetArrayLength(pixels) != static_cast<jsize>(rows) * state.image_width * channels) return JNI_FALSE;
    using Clock = std::chrono::steady_clock;
    const auto t0 = Clock::now();
    jbyte* source = env->GetByteArrayElements(pixels, nullptr);
    if (!source) return JNI_FALSE;
    const auto t1 = Clock::now();
    std::vector<jbyte> expanded;
    const jbyte* data = source;
    if (channels == 3) {
        const size_t count = static_cast<size_t>(rows) * state.image_width;
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
        glBindTexture(GL_TEXTURE_2D, state.acquired);
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, y, state.image_width, rows, GL_RGBA, GL_UNSIGNED_BYTE, data);
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
Java_org_vrpassthroughplayer_plugin_VideoLayerNative_copyBand(JNIEnv*, jclass, jint texture, jint y, jint rows) {
    std::lock_guard<std::mutex> lock(mutex);
    if (!state.acquired || texture <= 0 || y < 0 || rows <= 0 || y + rows > state.image_height || !glIsTexture(static_cast<GLuint>(texture)))
        return JNI_FALSE;
    while (glGetError() != GL_NO_ERROR) {}
    glCopyImageSubData(static_cast<GLuint>(texture), GL_TEXTURE_2D, 0, 0, 0, 0,
                       state.acquired, GL_TEXTURE_2D, 0, 0, y, 0, state.image_width, rows, 1);
    const GLenum error = glGetError();
    if (error != GL_NO_ERROR) log(ANDROID_LOG_WARN, "copyBand GL error " + std::to_string(error));
    return error == GL_NO_ERROR ? JNI_TRUE : JNI_FALSE;
}

/** GPU copy of a whole GL_TEXTURE_2D (same size, RGBA8) into level 0 of the acquired image. */
extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_VideoLayerNative_copyTexture(JNIEnv*, jclass, jint texture) {
    std::lock_guard<std::mutex> lock(mutex);
    if (!state.acquired || texture <= 0 || !glIsTexture(static_cast<GLuint>(texture))) return JNI_FALSE;
    while (glGetError() != GL_NO_ERROR) {}
    glCopyImageSubData(static_cast<GLuint>(texture), GL_TEXTURE_2D, 0, 0, 0, 0,
                       state.acquired, GL_TEXTURE_2D, 0, 0, 0, 0, state.image_width, state.image_height, 1);
    return glGetError() == GL_NO_ERROR ? JNI_TRUE : JNI_FALSE;
}
