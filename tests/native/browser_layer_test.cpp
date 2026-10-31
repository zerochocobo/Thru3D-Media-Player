// Exercises the production JNI entry points with an OpenXR/Surface test double.
#include "../../native/xr-layer/browser_layer.cpp"
#include <algorithm>
#include <cstring>
#include <iostream>

namespace fixture {
int created = 0, destroyed = 0, global_refs = 0;
bool fail_create = false;
XrSwapchainCreateInfo last_info{};
struct Floats { jsize length = 14; std::array<float, 14> data{}; };
jobject JNICALL new_ref(JNIEnv*, jobject value) { ++global_refs; return value; }
void JNICALL delete_ref(JNIEnv*, jobject) { --global_refs; }
void JNICALL delete_local(JNIEnv*, jobject) {}
jboolean JNICALL exception(JNIEnv*) { return false; }
jsize JNICALL length(JNIEnv*, jarray value) { return reinterpret_cast<Floats*>(value)->length; }
void JNICALL read(JNIEnv*, jfloatArray value, jsize start, jsize count, jfloat* target) {
    auto* floats = reinterpret_cast<Floats*>(value);
    std::copy_n(floats->data.data() + start, count, target);
}
XrResult XRAPI_CALL create_surface(XrSession, const XrSwapchainCreateInfo* info, XrSwapchain* swapchain, jobject* surface) {
    last_info = *info;
    if (fail_create) return XR_ERROR_RUNTIME_FAILURE;
    *swapchain = reinterpret_cast<XrSwapchain>(static_cast<uintptr_t>(100 + ++created));
    *surface = reinterpret_cast<jobject>(static_cast<uintptr_t>(200 + created));
    return XR_SUCCESS;
}
XrResult XRAPI_CALL destroy_surface(XrSwapchain) { ++destroyed; return XR_SUCCESS; }
XrResult XRAPI_CALL get_proc(XrInstance, const char* name, PFN_xrVoidFunction* result) {
    if (std::strcmp(name, "xrCreateSwapchainAndroidSurfaceKHR") == 0) *result = reinterpret_cast<PFN_xrVoidFunction>(create_surface);
    else if (std::strcmp(name, "xrDestroySwapchain") == 0) *result = reinterpret_cast<PFN_xrVoidFunction>(destroy_surface);
    else return XR_ERROR_FUNCTION_UNSUPPORTED;
    return XR_SUCCESS;
}
}

int main() {
    int checks = 0, failures = 0;
    auto check = [&](bool ok, const char* message) { ++checks; if (!ok) { ++failures; std::cerr << message << '\n'; } };
    JNINativeInterface_ table{};
    table.NewGlobalRef = fixture::new_ref; table.DeleteGlobalRef = fixture::delete_ref; table.DeleteLocalRef = fixture::delete_local;
    table.ExceptionCheck = fixture::exception; table.GetArrayLength = fixture::length; table.GetFloatArrayRegion = fixture::read;
    JNIEnv env{&table};
    auto create = [&](int id, int session = 2) {
        return Java_org_vrpassthroughplayer_plugin_WebBrowserLayerNative_create(&env, nullptr, id, 1, session,
            static_cast<jlong>(reinterpret_cast<uintptr_t>(fixture::get_proc)), 2400, 1500);
    };
    auto destroy = [&](int id) { Java_org_vrpassthroughplayer_plugin_WebBrowserLayerNative_destroy(&env, nullptr, id); };
    fixture::Floats values{14, {0, 1.6f, -2, 0, 0, 0, 2, 1.44f, 0.9f, 480, 225, 960, 600, 1}};
    auto update = [&](int id) {
        return reinterpret_cast<const XrCompositionLayerQuad*>(Java_org_vrpassthroughplayer_plugin_WebBrowserLayerNative_update(
            &env, nullptr, id, 3, reinterpret_cast<jfloatArray>(&values)));
    };
    check(!create(0) && !create(6) && fixture::created == 0, "Invalid window cannot create a producer");
    check(create(1) && fixture::created == 1 && fixture::global_refs == 1, "Creating holds exactly one Surface reference");
    check(fixture::last_info.width == 2400 && fixture::last_info.height == 1500 && fixture::last_info.format == 0 && fixture::last_info.sampleCount == 0,
        "Browser retains its original raster and Android Surface creation requirements");
    check(!create(1) && fixture::destroyed == 0, "A live producer cannot be replaced without acknowledged destruction");
    const auto* layer = update(1);
    check(layer && layer->subImage.imageRect.offset.y == 675 && layer->subImage.imageRect.extent.width == 960, "Production JNI submits the selected source pixels");
    check(layer && layer->pose.orientation.w == 1 && layer->space == reinterpret_cast<XrSpace>(3), "Pose is normalized in the supplied reference space");
    auto swapchain = layer->subImage.swapchain;
    values.data[13] = 0;
    check(update(1)->subImage.imageRect.offset.y == 225, "No-flip runtime retains top-left crop origin");
    values.data[9] = 0; values.data[10] = 0; values.data[11] = 2400; values.data[12] = 1500;
    check(update(1)->subImage.swapchain == swapchain && fixture::created == 1 && fixture::destroyed == 0, "Exiting focus reuses the very same producer");
    values.data[9] = 1;
    check(!update(1), "Overflow crop cannot reach the frame provider");
    values.data[9] = NAN;
    check(!update(1), "Non-finite input cannot reach the frame provider");
    values.data[9] = 0; values.length = 13;
    check(!update(1), "Malformed JNI payload is rejected");
    values.length = 14;
    check(create(2) && update(2)->subImage.swapchain != swapchain, "Peer window has an independent swapchain");
    destroy(1); destroy(1);
    check(fixture::destroyed == 1 && fixture::global_refs == 1 && !update(1) && update(2), "Closing is idempotent and leaves the peer alive");
    check(create(1), "Acknowledged close permits resize/recreation");
    const int destroyed_before = fixture::destroyed;
    check(create(1, 4) && fixture::destroyed == destroyed_before && fixture::global_refs == 2, "A new session releases stale references without double-destroying old-session handles");
    destroy(1); destroy(2);
    check(fixture::global_refs == 0, "Closing all browser windows releases all Surface references");
    check(create(1) && create(5) && update(1)->subImage.swapchain != update(5)->subImage.swapchain, "Account login uses its own Surface while a browser exists");
    destroy(5);
    check(update(1) && !update(5), "Closing an account cannot destroy the ordinary browser");
    destroy(1);
    fixture::fail_create = true;
    check(!create(1) && fixture::global_refs == 0 && !update(1), "Failed creation cannot expose a dangling layer");
    std::cout << "Browser native layer: " << checks << " checks, " << failures << " failures\n";
    return failures ? 1 : 0;
}
