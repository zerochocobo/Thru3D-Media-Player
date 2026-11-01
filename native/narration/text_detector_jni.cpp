#include "text_detector.h"
#include "jni_text.h"
#include <cstring>
extern "C" JNIEXPORT jlong JNICALL Java_org_vrpassthroughplayer_plugin_TextDetectorNative_create(JNIEnv* env,jclass,jstring model){
    return text_detector_create(narration_utf8(env,model).c_str());
}
extern "C" JNIEXPORT void JNICALL Java_org_vrpassthroughplayer_plugin_TextDetectorNative_cancel(JNIEnv*,jclass,jlong id,jlong token){text_detector_cancel(id,token);}
extern "C" JNIEXPORT void JNICALL Java_org_vrpassthroughplayer_plugin_TextDetectorNative_destroy(JNIEnv*,jclass,jlong id){text_detector_destroy(id);}
extern "C" JNIEXPORT jstring JNICALL Java_org_vrpassthroughplayer_plugin_TextDetectorNative_detect(JNIEnv* env,jclass,jlong id,jobject input,jint w,jint h,jlong token){
    if(!input||w<32||h<32||w>1024||h>1024||w%32||h%32||env->GetDirectBufferCapacity(input)!=int64_t(w)*h*12){
        narration_error(env,"text_input_size");return nullptr;}
    auto rgb=static_cast<const float*>(env->GetDirectBufferAddress(input));
    const char* text=text_detector_run(id,rgb,w,h,token);
    auto output=env->NewStringUTF(text);text_detector_free(text);return output;
}
