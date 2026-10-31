// Browser quads use the same Android Surface swapchain path as video_layer.cpp.
// A real subImage crop keeps Gecko's viewport/session intact and cannot leak into peer holes.
#include <jni.h>
#include <array>
#include <cmath>
#define XR_USE_PLATFORM_ANDROID
#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>
#include "layer_layout.h"

namespace {
struct BrowserLayer {
    XrSession session = XR_NULL_HANDLE;
    XrSwapchain swapchain = XR_NULL_HANDLE;
    PFN_xrDestroySwapchain destroy = nullptr;
    jobject surface = nullptr;
    int width = 0, height = 0;
    XrCompositionLayerQuad quad{};
    XrCompositionLayerImageLayoutFB layout{};
};
// Accessed only on Godot's frame thread, like VideoLayer's provider addresses.
// Four ordinary browser slots plus one isolated account-login surface.
std::array<BrowserLayer, 5> layers;
BrowserLayer* slot(int id) { return id >= 1 && id <= 5 ? &layers[id - 1] : nullptr; }
void release(JNIEnv* env, BrowserLayer& layer, bool destroy) {
    if (destroy && layer.swapchain && layer.destroy) layer.destroy(layer.swapchain);
    if (layer.surface) env->DeleteGlobalRef(layer.surface);
    layer = {};
}
}

extern "C" JNIEXPORT jobject JNICALL
Java_org_vrpassthroughplayer_plugin_WebBrowserLayerNative_create(JNIEnv* env, jclass, jint id,
        jlong instance, jlong session, jlong get_proc, jint width, jint height) {
    auto* layer = slot(id);
    if (!layer || !instance || !session || !get_proc || width < 256 || height < 256 || width > 4096 || height > 4096) return nullptr;
    auto xr_session = reinterpret_cast<XrSession>(static_cast<uintptr_t>(session));
    // A destroyed session already destroyed its children. Never destroy an old handle again.
    if (layer->swapchain && layer->session != xr_session) release(env, *layer, false);
    if (layer->swapchain) return nullptr; // Only the acknowledged detach path may replace a live producer.
    auto get = reinterpret_cast<PFN_xrGetInstanceProcAddr>(static_cast<uintptr_t>(get_proc));
    auto xr_instance = reinterpret_cast<XrInstance>(static_cast<uintptr_t>(instance));
    PFN_xrVoidFunction create_fn = nullptr, destroy_fn = nullptr;
    if (XR_FAILED(get(xr_instance, "xrCreateSwapchainAndroidSurfaceKHR", &create_fn)) || !create_fn ||
        XR_FAILED(get(xr_instance, "xrDestroySwapchain", &destroy_fn)) || !destroy_fn) return nullptr;
    XrSwapchainCreateInfo info{};
    info.type = XR_TYPE_SWAPCHAIN_CREATE_INFO;
    info.usageFlags = XR_SWAPCHAIN_USAGE_SAMPLED_BIT | XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT | XR_SWAPCHAIN_USAGE_MUTABLE_FORMAT_BIT;
    info.width = static_cast<uint32_t>(width); info.height = static_cast<uint32_t>(height);
    jobject surface = nullptr;
    XrSwapchain swapchain = XR_NULL_HANDLE;
    auto destroy = reinterpret_cast<PFN_xrDestroySwapchain>(destroy_fn);
    auto result = reinterpret_cast<PFN_xrCreateSwapchainAndroidSurfaceKHR>(create_fn)(xr_session, &info, &swapchain, &surface);
    if (XR_FAILED(result) || !swapchain || !surface) {
        if (swapchain) destroy(swapchain);
        if (surface) env->DeleteLocalRef(surface);
        return nullptr;
    }
    layer->surface = env->NewGlobalRef(surface);
    if (!layer->surface) { destroy(swapchain); env->DeleteLocalRef(surface); return nullptr; }
    layer->session = xr_session; layer->swapchain = swapchain; layer->destroy = destroy;
    layer->width = width; layer->height = height;
    return surface;
}

extern "C" JNIEXPORT void JNICALL
Java_org_vrpassthroughplayer_plugin_WebBrowserLayerNative_destroy(JNIEnv* env, jclass, jint id) {
    if (auto* layer = slot(id)) release(env, *layer, true);
}

// xyz, quaternion xyzw, size xy, crop xywh in top-left producer pixels, image-layout mode.
extern "C" JNIEXPORT jlong JNICALL
Java_org_vrpassthroughplayer_plugin_WebBrowserLayerNative_update(JNIEnv* env, jclass, jint id, jlong space, jfloatArray values) {
    auto* layer = slot(id);
    if (!layer || !layer->swapchain || !space || !values || env->GetArrayLength(values) != 14) return 0;
    std::array<float, 14> v{}; env->GetFloatArrayRegion(values, 0, 14, v.data());
    if (env->ExceptionCheck()) return 0;
    for (auto f : v) if (!std::isfinite(f)) return 0;
    if (v[7] <= 0 || v[8] <= 0 || !quest::image_rect_valid(v.data() + 9, layer->width, layer->height)) return 0;
    const float norm = std::sqrt(v[3]*v[3] + v[4]*v[4] + v[5]*v[5] + v[6]*v[6]);
    if (norm < 0.001f) return 0;
    auto& quad = layer->quad;
    quad = {}; quad.type = XR_TYPE_COMPOSITION_LAYER_QUAD;
    quad.space = reinterpret_cast<XrSpace>(static_cast<uintptr_t>(space));
    quad.eyeVisibility = XR_EYE_VISIBILITY_BOTH;
    quad.pose = {{v[3]/norm, v[4]/norm, v[5]/norm, v[6]/norm}, {v[0], v[1], v[2]}};
    quad.size = {v[7], v[8]};
    quad.subImage.swapchain = layer->swapchain;
    quad.subImage.imageRect = quest::browser_image_rect(v.data() + 9, layer->height, v[13] > 0.5f);
    quad.next = quest::image_layout_next(layer->layout, v[13], nullptr);
    return static_cast<jlong>(reinterpret_cast<uintptr_t>(&quad));
}
