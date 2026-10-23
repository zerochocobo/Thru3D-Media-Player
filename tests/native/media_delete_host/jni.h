#pragma once
// Host-only byte-array boundary. Filesystem operations come from production JNI
// source and execute real Linux syscalls; this is never an Android include path.
#include <cstdint>
#include <cstring>
#include <vector>
#define JNIEXPORT
#define JNICALL
using jint = int32_t;
using jsize = int32_t;
using jbyte = int8_t;
using jboolean = unsigned char;
using jobject = void*;
using jbyteArray = std::vector<jbyte>*;
struct JNIEnv {
    bool ExceptionCheck() { return false; }
    jsize GetArrayLength(jbyteArray bytes) { return static_cast<jsize>(bytes->size()); }
    void GetByteArrayRegion(jbyteArray bytes, jsize start, jsize length, jbyte* target) {
        if (length) std::memcpy(target, bytes->data() + start, length);
    }
    jbyteArray NewByteArray(jsize length) { return new std::vector<jbyte>(length); }
    void DeleteLocalRef(jbyteArray bytes) { delete bytes; }
};
