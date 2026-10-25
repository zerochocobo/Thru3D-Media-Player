#include "comic_ocr.h"
#include "jni_text.h"
#include <vector>

extern "C" JNIEXPORT jlong JNICALL Java_org_vrpassthroughplayer_plugin_ComicOcrNative_create(JNIEnv* env,jclass,jstring directory){
    return comic_create(narration_utf8(env,directory).c_str());
}
extern "C" JNIEXPORT void JNICALL Java_org_vrpassthroughplayer_plugin_ComicOcrNative_cancel(JNIEnv*,jclass,jlong handle,jlong token){comic_cancel(handle,token);}
extern "C" JNIEXPORT void JNICALL Java_org_vrpassthroughplayer_plugin_ComicOcrNative_destroy(JNIEnv*,jclass,jlong handle){comic_destroy(handle);}
extern "C" JNIEXPORT jbyteArray JNICALL Java_org_vrpassthroughplayer_plugin_ComicOcrNative_analyze(JNIEnv* env,jclass,jlong handle,jbyteArray bytes,jint w,jint h,jlong token,jboolean unrestricted){
    if(!bytes||w<16||h<16||w>1600||h>1600||env->GetArrayLength(bytes)!=w*h*3){narration_error(env,"comic_page_size");return nullptr;}
    std::vector<uint8_t> rgb(size_t(w)*h*3);env->GetByteArrayRegion(bytes,0,jsize(rgb.size()),reinterpret_cast<jbyte*>(rgb.data()));
    if(env->ExceptionCheck())return nullptr;
    const char* result=unrestricted?comic_analyze_unrestricted(handle,rgb.data(),w,h,token):comic_analyze(handle,rgb.data(),w,h,token);
    size_t length=std::char_traits<char>::length(result);
    auto output=env->NewByteArray(jsize(length));if(output)env->SetByteArrayRegion(output,0,jsize(length),reinterpret_cast<const jbyte*>(result));
    comic_free(result);return output;
}
