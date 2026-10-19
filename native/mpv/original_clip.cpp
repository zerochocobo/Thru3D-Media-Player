// Independent packet-copy JNI. The same core runs in the host integration fixture.
#include "original_clip_core.h"
#ifndef THRU3D_CAPTURE_HOST
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
extern "C" JNIEXPORT jstring JNICALL
Java_org_vrpassthroughplayer_plugin_OriginalClipNative_export(JNIEnv* env,jclass,jint id,jstring source,
    jstring output,jlong start,jlong end,jint audio,jstring extra_audio,jstring ca,jstring mode) {
    std::shared_ptr<quest::capture::Control> control;
    { std::lock_guard<std::mutex> lock(jobs_mutex); auto found=jobs.find(id); if (found!=jobs.end()) control=found->second; }
    if (!control) return env->NewStringUTF("{\"state\":\"error\",\"error\":\"Clip export cancelled\"}");
    std::string result;
    try { result=quest::capture::clip(text(env,source),text(env,output),start,end,audio,text(env,extra_audio),text(env,ca),text(env,mode),*control); }
    catch (...) { result="{\"state\":\"error\",\"error\":\"Clip export failed\"}"; }
    { std::lock_guard<std::mutex> lock(jobs_mutex); jobs.erase(id); }
    return env->NewStringUTF(result.c_str());
}
#else
#include <iostream>
int main(int argc,char** argv) {
    if (argc!=6 && argc!=7) return 2;
    quest::capture::Control control;
    const auto result=quest::capture::clip(argv[1],argv[2],std::stoll(argv[3]),std::stoll(argv[4]),std::stoi(argv[5]),
        argc==7 ? argv[6] : "","","{\"version\":1,\"geometry\":3,\"stereo_sbs\":true}",control);
    std::cout<<result<<'\n';
    return result.find("\"state\":\"saved\"")==std::string::npos ? 1 : 0;
}
#endif
