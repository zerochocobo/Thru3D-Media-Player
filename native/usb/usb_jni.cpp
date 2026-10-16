#include "usb_fs.h"
#include <jni.h>
#include <algorithm>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>
namespace {
JavaVM* vm=nullptr;
struct Callback {
    jobject object; jmethodID read;
    explicit Callback(JNIEnv* e,jobject o) : object(e->NewGlobalRef(o)) { auto c=e->GetObjectClass(o); read=e->GetMethodID(c,"read","(J[B)I"); e->DeleteLocalRef(c); if(!object||!read) { if(e->ExceptionCheck()) e->ExceptionClear(); if(object) e->DeleteGlobalRef(object); throw std::runtime_error("USB reader unavailable"); } }
    ~Callback() { JNIEnv* e=nullptr; bool attached=vm->GetEnv(reinterpret_cast<void**>(&e),JNI_VERSION_1_6)!=JNI_OK; if(attached) vm->AttachCurrentThread(&e,nullptr); if(e) e->DeleteGlobalRef(object); if(attached) vm->DetachCurrentThread(); }
    bool operator()(uint64_t at,void* data,size_t n) {
        JNIEnv* e=nullptr; bool attached=vm->GetEnv(reinterpret_cast<void**>(&e),JNI_VERSION_1_6)!=JNI_OK;
        if(attached && vm->AttachCurrentThread(&e,nullptr)!=JNI_OK) return false;
        bool ok=true; auto* out=static_cast<jbyte*>(data);
        while(n && ok) {
            jsize part=std::min<size_t>(n,512*1024); auto b=e->NewByteArray(part);
            if(!b) { if(e->ExceptionCheck()) e->ExceptionClear(); ok=false; break; }
            jint got=e->CallIntMethod(object,read,static_cast<jlong>(at),b);
            if(e->ExceptionCheck()) { e->ExceptionClear(); ok=false; }
            else if(got!=part) ok=false;
            else e->GetByteArrayRegion(b,0,part,out);
            e->DeleteLocalRef(b); at+=part; out+=part; n-=part;
        }
        if(attached) vm->DetachCurrentThread(); return ok;
    }
};
std::string bytes(JNIEnv* e,jbyteArray a) { auto n=e->GetArrayLength(a); if(n>8192) throw std::runtime_error("USB path too long"); std::string s(n,'\0'); e->GetByteArrayRegion(a,0,n,reinterpret_cast<jbyte*>(s.data())); return s; }
void fail(JNIEnv* e,const std::exception& error) { if(!e->ExceptionCheck()) e->ThrowNew(e->FindClass("java/io/IOException"),error.what()); }
std::string quote(const std::string& s) { std::string o="\""; for(unsigned char c:s) { if(c=='"'||c=='\\') { o+='\\'; o+=c; } else if(c<32) { const char hex[]="0123456789abcdef"; o+="\\u00"; o+=hex[c>>4]; o+=hex[c&15]; } else o+=c; } return o+'"'; }
}
extern "C" JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* v,void*) { vm=v; return JNI_VERSION_1_6; }
#define JNI_FN(name) Java_org_vrpassthroughplayer_plugin_UsbFsNative_##name
extern "C" JNIEXPORT jlong JNICALL JNI_FN(mount)(JNIEnv* e,jclass,jobject reader,jlong length,jint sector,jboolean ntfs) {
    try { auto cb=std::make_shared<Callback>(e,reader); return usb::mount([cb](uint64_t at,void* p,size_t n){return (*cb)(at,p,n);},length,sector,ntfs); } catch(const std::exception& x) { fail(e,x); return 0; }
}
extern "C" JNIEXPORT jbyteArray JNICALL JNI_FN(list)(JNIEnv* e,jclass,jlong id,jbyteArray path) {
    try { auto entries=usb::list(id,bytes(e,path)); std::string json="["; for(auto& entry:entries) { if(json.size()>1) json+=','; json+="{\"name\":"+quote(entry.name)+",\"directory\":"+(entry.directory?"true":"false")+",\"size\":"+std::to_string(entry.size)+'}'; } json+=']'; auto out=e->NewByteArray(json.size()); if(out) e->SetByteArrayRegion(out,0,json.size(),reinterpret_cast<const jbyte*>(json.data())); return out; } catch(const std::exception& x) { fail(e,x); return nullptr; }
}
extern "C" JNIEXPORT jlong JNICALL JNI_FN(open)(JNIEnv* e,jclass,jlong id,jbyteArray path) { try { return usb::open(id,bytes(e,path)); } catch(const std::exception& x) { fail(e,x); return 0; } }
extern "C" JNIEXPORT jlong JNICALL JNI_FN(size)(JNIEnv* e,jclass,jlong id) { try { return usb::size(id); } catch(const std::exception& x) { fail(e,x); return 0; } }
extern "C" JNIEXPORT jint JNICALL JNI_FN(read)(JNIEnv* e,jclass,jlong id,jlong offset,jbyteArray buffer,jint n) {
    try { if(offset<0||n<0||n>e->GetArrayLength(buffer)||n>1024*1024) throw std::runtime_error("Invalid USB read"); std::vector<unsigned char> b(n); auto got=usb::read(id,offset,b.data(),n); if(got) e->SetByteArrayRegion(buffer,0,got,reinterpret_cast<const jbyte*>(b.data())); return got; } catch(const std::exception& x) { fail(e,x); return -1; }
}
extern "C" JNIEXPORT void JNICALL JNI_FN(closeFile)(JNIEnv* e,jclass,jlong id) { try { usb::close_file(id); } catch(const std::exception& x) { fail(e,x); } }
extern "C" JNIEXPORT void JNICALL JNI_FN(closeVolume)(JNIEnv* e,jclass,jlong id) { try { usb::close_volume(id); } catch(const std::exception& x) { fail(e,x); } }
