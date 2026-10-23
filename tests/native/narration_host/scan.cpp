#include "jni.h"
#include <iostream>
#include <iomanip>
extern "C" jlong Java_org_vrpassthroughplayer_plugin_VoiceCloneNative_createJob(JNIEnv*,jclass);
extern "C" void Java_org_vrpassthroughplayer_plugin_VoiceCloneNative_cancelJob(JNIEnv*,jclass,jlong);
extern "C" jstring Java_org_vrpassthroughplayer_plugin_VoiceCloneNative_probe(JNIEnv*,jclass,jlong,jstring,jstring,jboolean,jint);
extern "C" void Java_org_vrpassthroughplayer_plugin_VoiceCloneNative_scan(JNIEnv*,jclass,jlong,jstring,jint,jstring,jdouble,jdouble,jboolean,jint,jstring,jobject);
extern "C" void Java_org_vrpassthroughplayer_plugin_VoiceCloneNative_extract(JNIEnv*,jclass,jlong,jstring,jint,jstring,jdouble,jdouble,jstring,jboolean,jint);
int main(int argc,char** argv) {
    if(argc!=7)return 2;
    JNIEnv env;auto job=Java_org_vrpassthroughplayer_plugin_VoiceCloneNative_createJob(&env,nullptr);
    auto path=env.NewStringUTF(argv[2]),empty=env.NewStringUTF(""),model=env.NewStringUTF(argv[6]);
    const std::string mode=argv[1];int callbacks=0;bool done=false;
    if(mode=="probe"){
        auto result=Java_org_vrpassthroughplayer_plugin_VoiceCloneNative_probe(&env,nullptr,job,path,empty,0,-1);
        if(result)for(char16_t c:*result)std::cout<<char(c);
    }else if(mode=="extract"){
        Java_org_vrpassthroughplayer_plugin_VoiceCloneNative_extract(&env,nullptr,job,path,std::stoi(argv[3]),empty,std::stod(argv[4]),std::stod(argv[5]),model,0,-1);
    }else{
        std::cout<<"{\"frames\":[";bool first=true;
        env.onFrames=[&](double start,jfloatArray p,jfloatArray r,jfloatArray k,jboolean finished){
            ++callbacks;done=finished;
            for(size_t i=0;i<p->size();++i){if(!first)std::cout<<',';first=false;
                std::cout<<'['<<std::setprecision(10)<<start+i*.032<<','<<(*p)[i]<<','<<(*r)[i]<<','<<(*k)[i]<<']';}
            if(mode=="cancel")Java_org_vrpassthroughplayer_plugin_VoiceCloneNative_cancelJob(&env,nullptr,job);
            return JNI_TRUE;
        };
        Java_org_vrpassthroughplayer_plugin_VoiceCloneNative_scan(&env,nullptr,job,path,std::stoi(argv[3]),empty,std::stod(argv[4]),std::stod(argv[5]),0,-1,model,reinterpret_cast<jobject>(1));
        std::cout<<"],\"callbacks\":"<<callbacks<<",\"done\":"<<(done?"true":"false")<<",\"cancelled\":"<<(!env.error.empty()?"true":"false")<<'}';
    }
    Java_org_vrpassthroughplayer_plugin_VoiceCloneNative_cancelJob(&env,nullptr,job);
    if(!env.error.empty()&&mode!="cancel"){std::cerr<<env.error;return 1;}
    return env.arrays.empty()?0:3;
}
