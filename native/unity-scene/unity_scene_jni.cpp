// Android entry (UnityScene.kt in the player plugin): returns null on success or a short failure reason.
#include <jni.h>

#include "etc2_encoder.h"
#include "unity_scene.h"

extern "C" JNIEXPORT jstring JNICALL
Java_org_vrpassthroughplayer_plugin_UnityScene_unpack(JNIEnv* env, jobject, jstring bundle, jstring output, jint max_texture, jint max_sky_texture) {
    const char* bundle_path = env->GetStringUTFChars(bundle, nullptr);
    const char* output_path = env->GetStringUTFChars(output, nullptr);
    char error[256] = {};
    int result = 1;
    if (bundle_path && output_path) result = thru3d_unity_scene_unpack(bundle_path, output_path, max_texture, max_sky_texture, error, sizeof error);
    if (bundle_path) env->ReleaseStringUTFChars(bundle, bundle_path);
    if (output_path) env->ReleaseStringUTFChars(output, output_path);
    return result == 0 ? nullptr : env->NewStringUTF(error[0] ? error : "scene could not be read");
}

// RGBA8 pixels (a full mip chain when `chain`) to ETC2; null when the input does not fit its size.
extern "C" JNIEXPORT jbyteArray JNICALL
Java_org_vrpassthroughplayer_plugin_UnityScene_encodeEtc2(JNIEnv* env, jobject, jbyteArray rgba, jint width, jint height, jboolean alpha, jboolean chain, jint threads) {
    if (!rgba) return nullptr;
    size_t out_size = chain ? thru3d_etc2_chain_size(width, height, alpha) : thru3d_etc2_level_size(width, height, alpha);
    if (out_size == 0 || out_size > (size_t(1) << 30)) return nullptr;
    jbyteArray result = env->NewByteArray(jsize(out_size));
    if (!result) return nullptr;
    jsize in_size = env->GetArrayLength(rgba);
    jbyte* in = static_cast<jbyte*>(env->GetPrimitiveArrayCritical(rgba, nullptr));
    jbyte* out = in ? static_cast<jbyte*>(env->GetPrimitiveArrayCritical(result, nullptr)) : nullptr;
    int failed = 1;
    if (in && out) failed = thru3d_etc2_encode(reinterpret_cast<const uint8_t*>(in), size_t(in_size), width, height, alpha, chain,
                                               reinterpret_cast<uint8_t*>(out), out_size, threads);
    if (out) env->ReleasePrimitiveArrayCritical(result, out, 0);
    if (in) env->ReleasePrimitiveArrayCritical(rgba, in, JNI_ABORT);
    return failed ? nullptr : result;
}
