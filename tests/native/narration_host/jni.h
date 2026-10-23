#pragma once
// Host-only JNI boundary: run the unmodified production FFmpeg readers without
// loading Android, ORT, a headset or any personal media. Not an Android include.
#include <cstdint>
#include <memory>
#include <string>
#include <vector>
#include <functional>
#include <algorithm>
#define JNIEXPORT
#define JNICALL
using jlong = int64_t;
using jint = int32_t;
using jdouble = double;
using jboolean = unsigned char;
using jchar = char16_t;
using jsize = int32_t;
using jclass = void*;
using jobject = void*;
using jmethodID = void*;
using jfloatArray = std::vector<float>*;
using jstring = const std::u16string*;
constexpr jboolean JNI_TRUE = 1;
constexpr jboolean JNI_FALSE = 0;
struct JNIEnv {
    std::string error;
    std::vector<std::unique_ptr<std::u16string>> strings;
    std::vector<std::unique_ptr<std::vector<float>>> arrays;
    std::function<jboolean(jdouble,jfloatArray,jfloatArray,jfloatArray,jboolean)> onFrames;
    jclass GetObjectClass(jobject) { return nullptr; }
    jmethodID GetMethodID(jclass,const char*,const char*) { return reinterpret_cast<jmethodID>(1); }
    jfloatArray NewFloatArray(jsize count) { arrays.push_back(std::make_unique<std::vector<float>>(count));return arrays.back().get(); }
    void SetFloatArrayRegion(jfloatArray out,jsize start,jsize count,const float* input) { std::copy_n(input,count,out->begin()+start); }
    jboolean CallBooleanMethod(jobject,jmethodID,jdouble start,jfloatArray p,jfloatArray r,jfloatArray k,jboolean done) {return onFrames(start,p,r,k,done);}
    void DeleteLocalRef(void* ref) {arrays.erase(std::remove_if(arrays.begin(),arrays.end(),[&](const auto& item){return item.get()==ref;}),arrays.end());}
    const jchar* GetStringChars(jstring value, void*) { return value->data(); }
    jsize GetStringLength(jstring value) { return jsize(value->size()); }
    void ReleaseStringChars(jstring, const jchar*) {}
    bool ExceptionCheck() { return !error.empty(); }
    jclass FindClass(const char*) { return nullptr; }
    void ThrowNew(jclass, const char* message) { error = message; }
    jstring NewStringUTF(const char* value) {
        // Fixture paths and JSON response checks are ASCII; production UTF-8
        // conversion is compiled from jni_text.h as usual.
        auto text = std::make_unique<std::u16string>();
        while (*value) text->push_back(static_cast<unsigned char>(*value++));
        strings.push_back(std::move(text)); return strings.back().get();
    }
};
