#include "jni.h"
#include <iostream>
#include <string>
extern "C" jlong Java_org_vrpassthroughplayer_plugin_VoiceCloneNative_createJob(JNIEnv*,jclass);
extern "C" void Java_org_vrpassthroughplayer_plugin_VoiceCloneNative_cancelJob(JNIEnv*,jclass,jlong);
extern "C" void Java_org_vrpassthroughplayer_plugin_VoiceCloneNative_extract(JNIEnv*,jclass,jlong,jstring,jint,jstring,jdouble,jdouble,jstring,jboolean);
#ifdef NARRATION_HOST_SUBTITLES
extern "C" jlong Java_org_vrpassthroughplayer_plugin_NarrationNative_openReaderConfigured(JNIEnv*,jclass,jstring,jint,jstring,jboolean);
extern "C" jstring Java_org_vrpassthroughplayer_plugin_NarrationNative_readBatch(JNIEnv*,jclass,jlong,jdouble,jdouble);
extern "C" void Java_org_vrpassthroughplayer_plugin_NarrationNative_closeReader(JNIEnv*,jclass,jlong);
#endif
int main(int argc,char** argv) {
    if(argc!=7)return 2;
    JNIEnv env;
    auto path=env.NewStringUTF(argv[2]),empty=env.NewStringUTF(""),output=env.NewStringUTF(argv[6]);
    const int stream=std::stoi(argv[3]);
    const double start=std::stod(argv[4]),end=std::stod(argv[5]);
    if(std::string(argv[1])=="audio") {
        const auto job=Java_org_vrpassthroughplayer_plugin_VoiceCloneNative_createJob(&env,nullptr);
        Java_org_vrpassthroughplayer_plugin_VoiceCloneNative_extract(&env,nullptr,job,path,stream,empty,start,end,output,0);
        Java_org_vrpassthroughplayer_plugin_VoiceCloneNative_cancelJob(&env,nullptr,job);
    }
#ifdef NARRATION_HOST_SUBTITLES
    else if(std::string(argv[1])=="subtitles") {
        const auto reader=Java_org_vrpassthroughplayer_plugin_NarrationNative_openReaderConfigured(&env,nullptr,path,stream,empty,0);
        auto result=Java_org_vrpassthroughplayer_plugin_NarrationNative_readBatch(&env,nullptr,reader,start,end);
        if(result)for(auto c:*result)std::cout<<char(c);
        Java_org_vrpassthroughplayer_plugin_NarrationNative_closeReader(&env,nullptr,reader);
    }
#endif
    else return 2;
    if(!env.error.empty()){std::cerr<<env.error<<'\n';return 1;}
    return 0;
}
