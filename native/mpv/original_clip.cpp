// Independent packet-copy JNI. The same core runs in the host integration fixture.
#include "original_clip_core.h"
#include "embedded_cover_core.h"
#ifndef THRU3D_CAPTURE_HOST
#include "original_frame_core.h"
#include <android/bitmap.h>
#include <jni.h>
#include <mutex>
#include <unordered_map>
namespace {
std::mutex jobs_mutex;
std::unordered_map<int, std::shared_ptr<quest::capture::Control>> jobs;
std::string text(JNIEnv* env, jstring value) {
    if (!value) return "";
    const char* chars=env->GetStringUTFChars(value,nullptr);
    if (!chars) throw std::runtime_error("Capture source unavailable");
    std::string result(chars); env->ReleaseStringUTFChars(value,chars); return result;
}
}
extern "C" JNIEXPORT jint JNICALL
Java_org_vrpassthroughplayer_plugin_OriginalClipNative_version(JNIEnv*,jclass) { return 1; }
extern "C" JNIEXPORT void JNICALL
Java_org_vrpassthroughplayer_plugin_OriginalClipNative_cancel(JNIEnv*,jclass,jint id) {
    std::lock_guard<std::mutex> lock(jobs_mutex);
    auto found=jobs.find(id); if (found!=jobs.end()) found->second->cancelled.store(true);
}
extern "C" JNIEXPORT void JNICALL
Java_org_vrpassthroughplayer_plugin_OriginalClipNative_prepare(JNIEnv*,jclass,jint id) {
    std::lock_guard<std::mutex> lock(jobs_mutex); jobs[id]=std::make_shared<quest::capture::Control>();
}
extern "C" JNIEXPORT void JNICALL
Java_org_vrpassthroughplayer_plugin_OriginalClipNative_forget(JNIEnv*,jclass,jint id) {
    std::lock_guard<std::mutex> lock(jobs_mutex); jobs.erase(id);
}
extern "C" JNIEXPORT jint JNICALL
Java_org_vrpassthroughplayer_plugin_OriginalClipNative_progress(JNIEnv*,jclass,jint id) {
    std::lock_guard<std::mutex> lock(jobs_mutex);
    const auto found = jobs.find(id);
    return found == jobs.end() ? -1 : found->second->progress.load();
}
extern "C" JNIEXPORT jobject JNICALL
Java_org_vrpassthroughplayer_plugin_OriginalClipNative_frame(JNIEnv* env,jclass,jint id,jstring source,jlong position,jstring ca) {
    jobject bitmap = nullptr;
    void* pixels = nullptr;
    try {
        std::shared_ptr<quest::capture::Control> control;
        { std::lock_guard<std::mutex> lock(jobs_mutex); auto found=jobs.find(id); if(found!=jobs.end())control=found->second; }
        if (!control) throw std::runtime_error("Could not capture source frame");
        control->deadline = std::chrono::steady_clock::now() + std::chrono::seconds(60);
        auto decoded = quest::capture::source_frame(text(env,source),position,text(env,ca),*control);
        if (quest::capture::Control::interrupt(control.get())) throw std::runtime_error("Could not capture source frame");
        const auto type = env->FindClass("android/graphics/Bitmap");
        const auto config_type = env->FindClass("android/graphics/Bitmap$Config");
        if (!type || !config_type || env->ExceptionCheck()) return nullptr;
        const auto config_field = env->GetStaticFieldID(config_type,"ARGB_8888","Landroid/graphics/Bitmap$Config;");
        const auto create = env->GetStaticMethodID(type,"createBitmap","(IILandroid/graphics/Bitmap$Config;)Landroid/graphics/Bitmap;");
        if (!config_field || !create || env->ExceptionCheck()) return nullptr;
        const auto config = env->GetStaticObjectField(config_type,config_field);
        bitmap = env->CallStaticObjectMethod(type,create,decoded->width,decoded->height,config);
        if (!bitmap || env->ExceptionCheck()) return nullptr;
        AndroidBitmapInfo info{};
        if (AndroidBitmap_getInfo(env,bitmap,&info)!=ANDROID_BITMAP_RESULT_SUCCESS ||
            info.format!=ANDROID_BITMAP_FORMAT_RGBA_8888 ||
            AndroidBitmap_lockPixels(env,bitmap,&pixels)!=ANDROID_BITMAP_RESULT_SUCCESS || !pixels)
            throw std::runtime_error("Could not capture source frame");
        quest::capture::frame_rgba(*decoded,static_cast<uint8_t*>(pixels),int(info.stride));
        AndroidBitmap_unlockPixels(env,bitmap); pixels=nullptr;
        return bitmap;
    } catch (const std::exception& failure) {
        if (pixels) AndroidBitmap_unlockPixels(env,bitmap);
        if (!env->ExceptionCheck()) {
            const char* message = dynamic_cast<const std::bad_alloc*>(&failure) ||
                std::string(failure.what())=="Full resolution capture unavailable" ?
                "Full resolution capture unavailable" : "Could not capture source frame";
            const auto type=env->FindClass("java/lang/IllegalStateException");
            if(type)env->ThrowNew(type,message);
        }
        return nullptr;
    }
}
extern "C" JNIEXPORT jbyteArray JNICALL
Java_org_vrpassthroughplayer_plugin_OriginalClipNative_cover(JNIEnv* env,jclass,jint id,jstring source,jstring ca) {
    try {
        std::shared_ptr<quest::capture::Control> control;
        {std::lock_guard<std::mutex> lock(jobs_mutex);auto found=jobs.find(id);if(found!=jobs.end())control=found->second;}
        if(!control)return env->NewByteArray(0);
        const auto bytes=quest::capture::embedded_cover(text(env,source),text(env,ca),*control);
        auto result=env->NewByteArray(bytes.size());
        if(result&&!bytes.empty())env->SetByteArrayRegion(result,0,bytes.size(),reinterpret_cast<const jbyte*>(bytes.data()));
        return result;
    }catch(...){return env->NewByteArray(0);}
}
extern "C" JNIEXPORT jstring JNICALL
Java_org_vrpassthroughplayer_plugin_OriginalClipNative_export(JNIEnv* env,jclass,jint id,jstring source,
    jstring output,jlong start,jlong end,jint audio,jstring extra_audio,jstring ca,jstring mode) {
    std::shared_ptr<quest::capture::Control> control;
    { std::lock_guard<std::mutex> lock(jobs_mutex); auto found=jobs.find(id); if (found!=jobs.end()) control=found->second; }
    if (!control) return env->NewStringUTF("{\"state\":\"error\",\"error\":\"Clip export cancelled\"}");
    std::string result;
    try { result=quest::capture::clip(text(env,source),text(env,output),start,end,audio,text(env,extra_audio),text(env,ca),text(env,mode),*control); }
    catch (...) { result="{\"state\":\"error\",\"error\":\"Clip export failed\"}"; }
    return env->NewStringUTF(result.c_str());
}
#else
#include <iostream>
int main(int argc,char** argv) {
    if (argc!=6 && argc!=7) return 2;
    quest::capture::Control control;
    const auto result=quest::capture::clip(argv[1],argv[2],std::stoll(argv[3]),std::stoll(argv[4]),std::stoi(argv[5]),
        argc==7 ? argv[6] : "","","{\"version\":1,\"geometry\":3,\"stereo_sbs\":true}",control);
    std::cout<<result.substr(0,result.size()-1)<<",\"progress\":"<<control.progress.load()<<"}"<<'\n';
    return result.find("\"state\":\"saved\"")==std::string::npos ? 1 : 0;
}
#endif
