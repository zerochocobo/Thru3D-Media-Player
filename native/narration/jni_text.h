#pragma once
#include <jni.h>
#include <string>

inline std::string narration_utf8(JNIEnv* env, jstring value) {
    if (!value) return {};
    const jchar* chars = env->GetStringChars(value, nullptr);
    if (!chars) return {};
    const jsize length = env->GetStringLength(value);
    std::string out;
    for (jsize i = 0; i < length; ++i) {
        uint32_t c = chars[i];
        if (c >= 0xd800 && c <= 0xdbff && i + 1 < length && chars[i+1] >= 0xdc00 && chars[i+1] <= 0xdfff)
            c = 0x10000 + ((c-0xd800)<<10) + (chars[++i]-0xdc00);
        else if (c >= 0xd800 && c <= 0xdfff) c = 0xfffd;
        if (c < 0x80) out += char(c);
        else if (c < 0x800) { out += char(0xc0|(c>>6)); out += char(0x80|(c&63)); }
        else if (c < 0x10000) { out += char(0xe0|(c>>12)); out += char(0x80|((c>>6)&63)); out += char(0x80|(c&63)); }
        else { out += char(0xf0|(c>>18)); out += char(0x80|((c>>12)&63)); out += char(0x80|((c>>6)&63)); out += char(0x80|(c&63)); }
    }
    env->ReleaseStringChars(value, chars);
    return out;
}
inline void narration_error(JNIEnv* env, const char* message) {
    if (!env->ExceptionCheck()) env->ThrowNew(env->FindClass("java/lang/IllegalStateException"), message);
}
