#include "pip_clip_core.h"
#include <android/bitmap.h>
#include <jni.h>

namespace {
struct Bitmap {
    JNIEnv* env; jobject object;void* pixels=nullptr;quest::pipshot::Image image;
    Bitmap(JNIEnv* e,jobject b):env(e),object(b) {
        AndroidBitmapInfo info{};
        if(!b||AndroidBitmap_getInfo(env,b,&info)!=ANDROID_BITMAP_RESULT_SUCCESS||info.format!=ANDROID_BITMAP_FORMAT_RGBA_8888||
           !info.width||!info.height||int64_t(info.width)*info.height>40*1024*1024||
           AndroidBitmap_lockPixels(env,b,&pixels)!=ANDROID_BITMAP_RESULT_SUCCESS||!pixels)throw std::runtime_error("Invalid bitmap");
        image={static_cast<const uint8_t*>(pixels),int(info.width),int(info.height),int(info.stride),
            (info.flags&ANDROID_BITMAP_FLAGS_ALPHA_MASK)==ANDROID_BITMAP_FLAGS_ALPHA_PREMUL};
    }
    ~Bitmap(){if(pixels)AndroidBitmap_unlockPixels(env,object);}
};
std::string text(JNIEnv* env,jstring value) {
    if(!value)throw std::runtime_error("Missing path");
    const char* p=env->GetStringUTFChars(value,nullptr);if(!p)throw std::bad_alloc();
    std::string result(p);env->ReleaseStringUTFChars(value,p);return result;
}
std::function<bool()> cancel(JNIEnv* env,jobject object) {
    if(!object)throw std::runtime_error("Missing cancellation");
    const auto cls=env->GetObjectClass(object);const auto method=env->GetMethodID(cls,"getAsBoolean","()Z");env->DeleteLocalRef(cls);
    if(!method)throw std::runtime_error("Missing cancellation");
    return [=](){return env->CallBooleanMethod(object,method)||env->ExceptionCheck();};
}
}
extern "C" JNIEXPORT jlong JNICALL Java_org_vrpassthroughplayer_plugin_PipClipNative_open(JNIEnv* env,jclass,jstring path) {
    try{return reinterpret_cast<jlong>(new quest::pipclip::Decoder(text(env,path)));}catch(...){return 0;}
}
extern "C" JNIEXPORT jintArray JNICALL Java_org_vrpassthroughplayer_plugin_PipClipNative_size(JNIEnv* env,jclass,jlong handle) {
    auto* decoder=reinterpret_cast<quest::pipclip::Decoder*>(handle);if(!decoder)return nullptr;
    auto* codec=decoder->local.input.ctx->streams[decoder->video]->codecpar;
    jint values[]={codec->width,codec->height};auto result=env->NewIntArray(2);if(result)env->SetIntArrayRegion(result,0,2,values);return result;
}
extern "C" JNIEXPORT jlong JNICALL Java_org_vrpassthroughplayer_plugin_PipClipNative_next(JNIEnv* env,jclass,jlong handle,jobject target,jobject cancelled) {
    try {
        auto* decoder=reinterpret_cast<quest::pipclip::Decoder*>(handle);if(!decoder)return -2;
        Bitmap bitmap(env,target);if(bitmap.image.width>3840||bitmap.image.height>3840)return -2;
        return decoder->next(static_cast<uint8_t*>(bitmap.pixels),bitmap.image.width,bitmap.image.height,bitmap.image.pitch,cancel(env,cancelled));
    }catch(const std::exception& error){return std::string(error.what())=="HDR picture in picture recording unavailable"?-3:-2;}
}
extern "C" JNIEXPORT void JNICALL Java_org_vrpassthroughplayer_plugin_PipClipNative_close(JNIEnv*,jclass,jlong handle) {
    delete reinterpret_cast<quest::pipclip::Decoder*>(handle);
}
extern "C" JNIEXPORT jboolean JNICALL Java_org_vrpassthroughplayer_plugin_PipClipNative_render(JNIEnv* env,jclass,jobject source,jobjectArray pictures,
    jintArray flags,jfloatArray recipe,jobjectArray planes,jintArray rows,jintArray strides,jobject cancelled) {
    try {
        if(!flags||!recipe||!pictures||!planes||!rows||!strides||env->GetArrayLength(flags)!=6||env->GetArrayLength(pictures)>3||
           env->GetArrayLength(recipe)>108||env->GetArrayLength(recipe)%36||env->GetArrayLength(planes)!=3||env->GetArrayLength(rows)!=3||env->GetArrayLength(strides)!=3)return false;
        Bitmap main(env,source);const int w=main.image.width,h=main.image.height;
        if(w>3840||h>3840||w%4||h%4)return false;
        jint mode[6],row[3],stride[3];env->GetIntArrayRegion(flags,0,6,mode);env->GetIntArrayRegion(rows,0,3,row);env->GetIntArrayRegion(strides,0,3,stride);
        std::vector<float> parameters(env->GetArrayLength(recipe));env->GetFloatArrayRegion(recipe,0,jsize(parameters.size()),parameters.data());
        std::vector<quest::pipshot::Window> windows;for(size_t i=0;i<parameters.size();i+=36)windows.emplace_back(parameters.data()+i);
        std::vector<std::unique_ptr<Bitmap>> locks;std::vector<quest::pipshot::Image> images;std::vector<jobject> refs;
        // Local refs are automatically reclaimed on return; Bitmap locks unwind before then.
        for(jsize i=0;i<env->GetArrayLength(pictures);++i){refs.push_back(env->GetObjectArrayElement(pictures,i));locks.emplace_back(std::make_unique<Bitmap>(env,refs.back()));images.push_back(locks.back()->image);}
        std::array<quest::pipclip::Plane,3> targets{};
        for(int i=0;i<3;++i) {
            auto buffer=env->GetObjectArrayElement(planes,i);
            targets[i]={static_cast<uint8_t*>(env->GetDirectBufferAddress(buffer)),env->GetDirectBufferCapacity(buffer),row[i],stride[i]};
        }
        quest::pipclip::compose_yuv(main.image,images,{mode[0],bool(mode[1]),bool(mode[2]),bool(mode[3]),bool(mode[4]),double(mode[5])},windows,targets,cancel(env,cancelled));
        return !env->ExceptionCheck();
    }catch(...){return false;}
}
extern "C" JNIEXPORT jboolean JNICALL Java_org_vrpassthroughplayer_plugin_PipClipNative_mux(JNIEnv* env,jclass,jstring video,jstring source,jstring output,jstring mode,jobject cancelled) {
    try{quest::pipclip::mux(text(env,video),text(env,source),text(env,output),text(env,mode),cancel(env,cancelled));return true;}catch(...){return false;}
}
