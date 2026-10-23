#include "pip_screenshot_core.h"
#include <android/bitmap.h>
#include <jni.h>
#include <memory>
#include <string>

namespace {
class Bitmap {
    JNIEnv* env; jobject bitmap;void* pixels=nullptr;
public:
    quest::pipshot::Image image;
    Bitmap(JNIEnv* e,jobject b):env(e),bitmap(b) {
        AndroidBitmapInfo info{};
        if(!b||AndroidBitmap_getInfo(env,b,&info)!=ANDROID_BITMAP_RESULT_SUCCESS||info.format!=ANDROID_BITMAP_FORMAT_RGBA_8888||
           !info.width||!info.height||int64_t(info.width)*info.height>40*1024*1024||
           AndroidBitmap_lockPixels(env,b,&pixels)!=ANDROID_BITMAP_RESULT_SUCCESS||!pixels)
            throw std::runtime_error("Bitmap unavailable");
        image={static_cast<const uint8_t*>(pixels),int(info.width),int(info.height),int(info.stride),
            (info.flags&ANDROID_BITMAP_FLAGS_ALPHA_MASK)==ANDROID_BITMAP_FLAGS_ALPHA_PREMUL};
    }
    ~Bitmap(){if(pixels)AndroidBitmap_unlockPixels(env,bitmap);env->DeleteLocalRef(bitmap);}
};
}
extern "C" JNIEXPORT jint JNICALL
Java_org_vrpassthroughplayer_plugin_PipScreenshotNative_version(JNIEnv*,jclass){return 1;}
extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_PipScreenshotNative_compose(JNIEnv* env,jclass,jobject source,jobjectArray pictures,
    jstring output,jintArray flags,jfloatArray recipe,jobject cancelled) {
    try {
        if(!source||!pictures||!output||!flags||!recipe||!cancelled||env->GetArrayLength(flags)!=6||
           env->GetArrayLength(pictures)>3||env->GetArrayLength(recipe)>108||env->GetArrayLength(recipe)%36)return false;
        jint mode[6];env->GetIntArrayRegion(flags,0,6,mode);
        std::vector<float> values(env->GetArrayLength(recipe));env->GetFloatArrayRegion(recipe,0,jsize(values.size()),values.data());
        std::vector<quest::pipshot::Window> windows;
        for(size_t i=0;i<values.size();i+=quest::pipshot::stride)windows.emplace_back(values.data()+i);
        const char* chars=env->GetStringUTFChars(output,nullptr);if(!chars)return false;
        const std::string path(chars);env->ReleaseStringUTFChars(output,chars);
        Bitmap main(env,env->NewLocalRef(source));
        std::vector<std::unique_ptr<Bitmap>> locks;std::vector<quest::pipshot::Image> images;
        for(jsize i=0;i<env->GetArrayLength(pictures);++i) {
            locks.emplace_back(std::make_unique<Bitmap>(env,env->GetObjectArrayElement(pictures,i)));
            images.push_back(locks.back()->image);
        }
        const jclass type=env->GetObjectClass(cancelled);const auto get=env->GetMethodID(type,"getAsBoolean","()Z");env->DeleteLocalRef(type);
        if(!get||env->ExceptionCheck())return false;
        quest::pipshot::compose(main.image,images,{mode[0],bool(mode[1]),bool(mode[2]),bool(mode[3]),bool(mode[4]),double(mode[5])},
            windows,path.c_str(),[&](){return env->CallBooleanMethod(cancelled,get)||env->ExceptionCheck();});
        return true;
    } catch(...) {return false;}
}
