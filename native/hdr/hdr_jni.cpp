#include "hdr_image.h"
#include <jni.h>
#include <stdexcept>
namespace {
std::string string(JNIEnv *env, jstring value) {
    if (!value) throw std::runtime_error("path");
    const char *text = env->GetStringUTFChars(value, nullptr);
    if (!text) throw std::runtime_error("path");
    std::string result(text); env->ReleaseStringUTFChars(value, text); return result;
}
}
extern "C" JNIEXPORT jintArray JNICALL
Java_org_vrpassthroughplayer_plugin_HdrPhotoNative_inspect(JNIEnv *env, jobject, jstring path) {
    try {
        auto info = thru::hdr_info(string(env, path));
        jint values[] = {info.width, info.height, 1, info.format};
        jintArray result = env->NewIntArray(4);
        if (result) env->SetIntArrayRegion(result, 0, 4, values);
        return result;
    } catch (...) { return nullptr; }
}
extern "C" JNIEXPORT jbyteArray JNICALL
Java_org_vrpassthroughplayer_plugin_HdrPhotoNative_pixels(JNIEnv *env, jobject, jstring path,
        jint left, jint top, jint width, jint height, jint sample, jobject checkpoint, jstring cache) {
    try {
        jmethodID run = nullptr;
        if (checkpoint) { auto cls = env->GetObjectClass(checkpoint); run = env->GetMethodID(cls, "run", "()V"); env->DeleteLocalRef(cls); }
        if (env->ExceptionCheck()) return nullptr;
        auto data = thru::hdr_pixels(string(env, path), left, top, width, height, sample, [&] {
            if (checkpoint && run) env->CallVoidMethod(checkpoint, run);
            if (env->ExceptionCheck()) throw std::runtime_error("cancelled");
        }, cache ? string(env, cache) : "");
        jbyteArray result = env->NewByteArray(jsize(data.size()));
        if (result) env->SetByteArrayRegion(result, 0, jsize(data.size()), reinterpret_cast<const jbyte *>(data.data()));
        return result;
    } catch (...) { return nullptr; }
}
