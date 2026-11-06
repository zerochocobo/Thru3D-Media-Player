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
    std::array<XrCompositionLayerQuad, 2> eyes{};
    XrCompositionLayerImageLayoutFB layout{};
};
// Accessed only on Godot's frame thread, like VideoLayer's provider addresses.
// Four browser slots, one login surface, and two alternating producers for one AirPlay window.
std::array<BrowserLayer, 7> layers;
BrowserLayer* slot(int id) { return id >= 1 && id <= 7 ? &layers[id - 1] : nullptr; }
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
    if (!layer || !instance || !session || !get_proc || width < 16 || height < 16 || width > 4096 || height > 4096) return nullptr;
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

// Borrow only on Godot's frame thread; stop the decoder before destroying its swapchain.
extern "C" JNIEXPORT jobject JNICALL
Java_org_vrpassthroughplayer_plugin_WebBrowserLayerNative_surface(JNIEnv* env, jclass, jint id) {
    auto* layer = slot(id);
    return id >= 6 && id <= 7 && layer && layer->surface ? env->NewLocalRef(layer->surface) : nullptr;
}

// Android decoder producers can change buffer dimensions without replacing their swapchain.
extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_WebBrowserLayerNative_producerSize(JNIEnv*, jclass, jint id, jint width, jint height) {
    auto* layer = slot(id);
    if (id < 6 || id > 7 || !layer || !layer->swapchain || width < 16 || height < 16 || width > 1920 || height > 1920) return false;
    layer->width = width; layer->height = height;
    return true;
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

// Processed browser producer packs both eyes into a single Android Surface.
extern "C" JNIEXPORT jlong JNICALL
Java_org_vrpassthroughplayer_plugin_WebBrowserLayerNative_updateEye(JNIEnv* env, jclass cls, jint id, jlong space, jfloatArray values, jint eye) {
    if (eye != 1 && eye != 2) return 0;
    auto address = Java_org_vrpassthroughplayer_plugin_WebBrowserLayerNative_update(env, cls, id, space, values);
    if (!address) return 0;
    auto* layer = slot(id);
    const auto& rect = layer->quad.subImage.imageRect;
    if (rect.extent.width % 2 != 0) return 0;
    auto& quad = layer->eyes[static_cast<size_t>(eye - 1)];
    quad = layer->quad;
    quad.eyeVisibility = eye == 1 ? XR_EYE_VISIBILITY_LEFT : XR_EYE_VISIBILITY_RIGHT;
    quad.subImage.imageRect.extent.width /= 2;
    quad.subImage.imageRect.offset.x += (eye - 1) * quad.subImage.imageRect.extent.width;
    return static_cast<jlong>(reinterpret_cast<uintptr_t>(&quad));
}
extern "C" JNIEXPORT jlong JNICALL
Java_org_vrpassthroughplayer_plugin_WebBrowserLayerNative_updateEyeAlpha(JNIEnv* env, jclass cls, jint id, jlong space, jfloatArray values, jint eye, jboolean alpha) {
    auto address = Java_org_vrpassthroughplayer_plugin_WebBrowserLayerNative_updateEye(env,cls,id,space,values,eye);
    if (address && alpha) {
        auto* quad = reinterpret_cast<XrCompositionLayerQuad*>(static_cast<uintptr_t>(address));
        // Browser effects write premultiplied RGBA, including feathered human silhouettes.
        quad->layerFlags |= XR_COMPOSITION_LAYER_BLEND_TEXTURE_SOURCE_ALPHA_BIT;
    }
    return address;
}
