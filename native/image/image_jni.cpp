#include "image_core.h"
#include <jni.h>
#include <GLES3/gl3.h>
#include <EGL/egl.h>
#include <atomic>
#include <cstring>
#include <mutex>
#include <unordered_map>
namespace {
using namespace thru::image;
struct Record {std::mutex lock;std::unique_ptr<Decoder> decoder;};
std::mutex registry_lock;
std::atomic<int64_t> sequence{1};
std::unordered_map<int64_t,std::shared_ptr<Record>> decoders;
std::unordered_map<int64_t,std::shared_ptr<Frame>> frames;
std::string text(JNIEnv* env,jstring path){if(!path)throw std::runtime_error("path");const char* chars=env->GetStringUTFChars(path,nullptr);if(!chars)throw std::runtime_error("path");std::string out(chars);env->ReleaseStringUTFChars(path,chars);return out;}
template<class T>std::shared_ptr<T> get(const std::unordered_map<int64_t,std::shared_ptr<T>>& values,int64_t id){std::lock_guard<std::mutex> lock(registry_lock);auto item=values.find(id);return item==values.end()?nullptr:item->second;}
jlongArray longs(JNIEnv* env,std::initializer_list<jlong> values){auto out=env->NewLongArray(jsize(values.size()));if(out)env->SetLongArrayRegion(out,0,jsize(values.size()),values.begin());return out;}
}
extern "C" JNIEXPORT jlong JNICALL Java_org_vrpassthroughplayer_plugin_ExtendedImageNative_open(JNIEnv* env,jobject,jstring path,jint edge,jboolean preview){
    try{auto item=std::make_shared<Record>();item->decoder=thru::image::open(text(env,path),edge,preview);auto id=sequence.fetch_add(1);std::lock_guard<std::mutex> lock(registry_lock);decoders[id]=item;return id;}catch(...){return 0;}
}
extern "C" JNIEXPORT jint JNICALL Java_org_vrpassthroughplayer_plugin_ExtendedImageNative_kind(JNIEnv* env,jobject,jstring path,jboolean raw){try{return int(thru::image::sniff(text(env,path),raw));}catch(...){return 0;}}
extern "C" JNIEXPORT jlongArray JNICALL Java_org_vrpassthroughplayer_plugin_ExtendedImageNative_info(JNIEnv* env,jobject,jlong id){auto item=get(decoders,id);if(!item)return nullptr;std::lock_guard<std::mutex> lock(item->lock);const auto& i=item->decoder->info;return longs(env,{int(i.kind),i.width,i.height,i.frames,i.plays,i.orientation,i.alpha?1:0,i.preview?1:0});}
extern "C" JNIEXPORT jlongArray JNICALL Java_org_vrpassthroughplayer_plugin_ExtendedImageNative_next(JNIEnv* env,jobject,jlong id,jobject checkpoint){
    auto item=get(decoders,id);if(!item)return nullptr;
    try{jmethodID run=nullptr;if(checkpoint){auto cls=env->GetObjectClass(checkpoint);run=env->GetMethodID(cls,"run","()V");env->DeleteLocalRef(cls);}if(env->ExceptionCheck())return nullptr;
        auto frame=std::make_shared<Frame>();std::lock_guard<std::mutex> work(item->lock);
        if(!item->decoder->next(*frame,[&]{if(checkpoint&&run)env->CallVoidMethod(checkpoint,run);if(env->ExceptionCheck())throw std::runtime_error("cancelled");}))return longs(env,{0,0,0,0});
        const auto token=sequence.fetch_add(1);{std::lock_guard<std::mutex> lock(registry_lock);frames[token]=frame;}
        return longs(env,{token,frame->width,frame->height,frame->duration_us});
    }catch(...){return nullptr;}
}
extern "C" JNIEXPORT void JNICALL Java_org_vrpassthroughplayer_plugin_ExtendedImageNative_reset(JNIEnv*,jobject,jlong id){auto item=get(decoders,id);if(item){std::lock_guard<std::mutex> lock(item->lock);try{item->decoder->reset();}catch(...){}}}
extern "C" JNIEXPORT jbyteArray JNICALL Java_org_vrpassthroughplayer_plugin_ExtendedImageNative_pixels(JNIEnv* env,jobject,jlong token){auto frame=get(frames,token);if(!frame)return nullptr;auto out=env->NewByteArray(jsize(frame->rgba.size()));if(out)env->SetByteArrayRegion(out,0,jsize(frame->rgba.size()),reinterpret_cast<const jbyte*>(frame->rgba.data()));return out;}
extern "C" JNIEXPORT jboolean JNICALL Java_org_vrpassthroughplayer_plugin_ExtendedImageNative_upload(JNIEnv*,jobject,jlong token,jint texture,jboolean mipmaps){
    auto frame=get(frames,token);if(!frame||texture<=0||eglGetCurrentContext()==EGL_NO_CONTEXT)return false;
    GLint binding=0,pbo=0,alignment=0,row=0,skipx=0,skipy=0;
    glGetIntegerv(GL_TEXTURE_BINDING_2D,&binding);glGetIntegerv(GL_PIXEL_UNPACK_BUFFER_BINDING,&pbo);glGetIntegerv(GL_UNPACK_ALIGNMENT,&alignment);
    glGetIntegerv(GL_UNPACK_ROW_LENGTH,&row);glGetIntegerv(GL_UNPACK_SKIP_PIXELS,&skipx);glGetIntegerv(GL_UNPACK_SKIP_ROWS,&skipy);
    glBindBuffer(GL_PIXEL_UNPACK_BUFFER,0);glPixelStorei(GL_UNPACK_ALIGNMENT,1);glPixelStorei(GL_UNPACK_ROW_LENGTH,0);glPixelStorei(GL_UNPACK_SKIP_PIXELS,0);glPixelStorei(GL_UNPACK_SKIP_ROWS,0);
    glBindTexture(GL_TEXTURE_2D,GLuint(texture));glTexSubImage2D(GL_TEXTURE_2D,0,0,0,frame->width,frame->height,GL_RGBA,GL_UNSIGNED_BYTE,frame->rgba.data());
    if(mipmaps)glGenerateMipmap(GL_TEXTURE_2D);
    const bool ok=glGetError()==GL_NO_ERROR;
    glBindTexture(GL_TEXTURE_2D,GLuint(binding));glBindBuffer(GL_PIXEL_UNPACK_BUFFER,GLuint(pbo));glPixelStorei(GL_UNPACK_ALIGNMENT,alignment);
    glPixelStorei(GL_UNPACK_ROW_LENGTH,row);glPixelStorei(GL_UNPACK_SKIP_PIXELS,skipx);glPixelStorei(GL_UNPACK_SKIP_ROWS,skipy);return ok;
}
extern "C" JNIEXPORT void JNICALL Java_org_vrpassthroughplayer_plugin_ExtendedImageNative_releaseFrame(JNIEnv*,jobject,jlong token){std::lock_guard<std::mutex> lock(registry_lock);frames.erase(token);}
extern "C" JNIEXPORT void JNICALL Java_org_vrpassthroughplayer_plugin_ExtendedImageNative_close(JNIEnv*,jobject,jlong id){std::shared_ptr<Record> item;{std::lock_guard<std::mutex> lock(registry_lock);auto found=decoders.find(id);if(found!=decoders.end()){item=std::move(found->second);decoders.erase(found);}}}
