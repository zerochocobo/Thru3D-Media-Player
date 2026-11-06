// Real production JNI renderer and stabilizer. Only Android/JNI objects and EGL ownership
// are host adapters. The builder records its narrow OES->2D desktop transport adaptation.
#include BROWSER_RENDER_BRIDGE_SOURCE
#include "../../../native/rvm/depth_stabilizer.h"
#include <unordered_map>

namespace host {
std::string last_error;
struct Buffer { void* data; jlong size; };
struct Floats { jsize size; const float* data; };
jboolean JNICALL exception(JNIEnv*) { return !last_error.empty(); }
jclass JNICALL find_class(JNIEnv*, const char*) { return reinterpret_cast<jclass>(1); }
jclass JNICALL object_class(JNIEnv*, jobject) { return reinterpret_cast<jclass>(1); }
jmethodID JNICALL method(JNIEnv*, jclass, const char*, const char*) { return reinterpret_cast<jmethodID>(1); }
jboolean JNICALL readonly(JNIEnv*, jobject, jmethodID, va_list) { return false; }
void JNICALL delete_local(JNIEnv*,jobject) {}
jint JNICALL throw_new(JNIEnv*,jclass,const char* message) { last_error=message;return 0; }
void* JNICALL data(JNIEnv*,jobject b) { return reinterpret_cast<Buffer*>(b)->data; }
jlong JNICALL capacity(JNIEnv*,jobject b) { return reinterpret_cast<Buffer*>(b)->size; }
jsize JNICALL length(JNIEnv*,jarray a) { return reinterpret_cast<Floats*>(a)->size; }
void JNICALL floats(JNIEnv*,jfloatArray a,jsize start,jsize count,jfloat* out) {
    auto* v=reinterpret_cast<Floats*>(a);if(start<0||count<0||start+count>v->size)throw std::runtime_error("JNI bounds");
    std::copy_n(v->data+start,count,out);
}
JNIEnv* env() {
    static JNINativeInterface_ table{};
    table.ExceptionCheck=exception;table.FindClass=find_class;table.ThrowNew=throw_new;
    table.GetObjectClass=object_class;table.GetMethodID=method;table.CallBooleanMethodV=readonly;table.DeleteLocalRef=delete_local;
    table.GetDirectBufferAddress=data;table.GetDirectBufferCapacity=capacity;
    table.GetArrayLength=length;table.GetFloatArrayRegion=floats;
    static JNIEnv value{&table};return &value;
}
std::unordered_map<jlong,std::unique_ptr<quest::DepthStabilizer>> stabilizers;
}
#define API extern "C" __declspec(dllexport)
API const char* bh_error() { return host::last_error.c_str(); }
API jlong bh_create(int w,int h,int iw,int ih) {
    host::last_error.clear();
    return Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_createLayout(host::env(),nullptr,w,h,iw,ih,0);
}
API void bh_destroy(jlong id) {
    Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_close(host::env(),nullptr,id);host::stabilizers.erase(id);
}
API int bh_options(jlong id,int borrow,int edge) {
    host::last_error.clear();
    if(!Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_setSlotLimit(host::env(),nullptr,id,2))return 0;
    if(borrow&&!Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_enableBorrowedColor(host::env(),nullptr,id))return 0;
    if(edge&&!Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_enableEdgeFill(host::env(),nullptr,id))return 0;
    return 1;
}
API jlong bh_capture(jlong id,const unsigned char* rgba,int sw,int sh,const float* crop) {
    try {
        host::last_error.clear();auto& b=find(id);
        glActiveTexture(GL_TEXTURE0);glBindTexture(GL_TEXTURE_2D,b.oes);
        glPixelStorei(GL_UNPACK_ALIGNMENT,1);glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,sw,sh,0,GL_RGBA,GL_UNSIGNED_BYTE,rgba);
        // Same producer-Y transform and crop composition as WebBrowserDepthGeometry.
        const float m[16]={crop[2],0,0,0, 0,-crop[3],0,0, 0,0,1,0, crop[0],crop[1]+crop[3],0,1};
        host::Floats a{16,m};
        auto token=Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_capture(host::env(),nullptr,id,reinterpret_cast<jfloatArray>(&a));
        glFinish();return token;
    } catch(const std::exception& e) { host::last_error=e.what();return 0; }
}
API int bh_inputs(jlong id,jlong token,float* rgb) {
    auto& b=find(id);host::Buffer out{rgb,static_cast<jlong>(b.input_width)*b.input_height*12};
    if(!Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_ready(host::env(),nullptr,id,token))return 0;
    return Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_readMonoInput(host::env(),nullptr,id,token,reinterpret_cast<jobject>(&out));
}
API void bh_content(jlong id,float* out) { auto& b=find(id);std::copy_n(b.content_rect.data(),4,out); }
API jlong bh_stage(jlong id,jlong parent,jlong token) {
    auto& b=find(parent);auto texture=b.find(token).source();
    auto t=Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_captureTexture(host::env(),nullptr,id,static_cast<jint>(texture),true);
    glFinish();return t;
}
API void bh_retire(jlong id,jlong token) {
    Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_retire(host::env(),nullptr,id,token);glFinish();
    if(!Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_retired(host::env(),nullptr,id,token))host::last_error="Retire fence";
}
API int bh_stabilize(jlong id,const float* raw,const float* rgb,float* near,int reset) {
    try {
        auto& b=find(id);auto& s=host::stabilizers[id];if(!s)s=std::make_unique<quest::DepthStabilizer>(b.input_width,b.input_height);
        if(reset)s->reset();
        auto r=b.content_rect;s->set_content(static_cast<int>(ceil(r[0]*b.input_width)),static_cast<int>(ceil(r[1]*b.input_height)),
            std::max(1,static_cast<int>(r[2]*b.input_width)),std::max(1,static_cast<int>(r[3]*b.input_height)));
        s->process(raw,rgb,1,near);return 1;
    } catch(const std::exception& e) { host::last_error=e.what();return 0; }
}
API int bh_render(jlong id,jlong token,const float* near,const unsigned char* matte,int mw,int mh,const float* rect,
                  float strength,float convergence,int fill,const char* vs,const char* fs,unsigned char* rgba) {
    try {
        host::last_error.clear();auto& b=find(id);
        if(!Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_ready(host::env(),nullptr,id,token))throw std::runtime_error("Color fence pending");
        GLuint color=b.find(token).source(), mask=0;bool packed=false;
        if(matte) {
            glGenTextures(1,&mask);glActiveTexture(GL_TEXTURE2);glBindTexture(GL_TEXTURE_2D,mask);
            glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
            glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);
            glPixelStorei(GL_UNPACK_ALIGNMENT,1);glTexImage2D(GL_TEXTURE_2D,0,GL_R8,mw,mh,0,GL_RED,GL_UNSIGNED_BYTE,matte);
        }
        if(near) {
            check_gl("Host browser pre-alpha state");
            const size_t n=static_cast<size_t>(b.input_width)*b.input_height;
            if(!b.find(token).alpha_valid&&!b.find(token).alpha_fence) {
                std::vector<float> right(near,near+n);b.upload_alpha(token,near,right.data());glFinish();
            }
            if(!b.alpha_ready(b.find(token)))throw std::runtime_error("Alpha fence");b.limit_near(token,.0175f*strength);
            if(fill) {
                host::Floats content{4,rect};
                auto texture=mask?Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_warpAlpha(host::env(),nullptr,id,token,.0175f*strength,convergence,mask,reinterpret_cast<jfloatArray>(&content))
                    :Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_warp(host::env(),nullptr,id,token,.0175f*strength,convergence);
                if(!texture)throw std::runtime_error("Fill unavailable on host GPU: "+host::last_error);color=texture;packed=true;
            }
        }
        auto v=shader(GL_VERTEX_SHADER,vs), f=shader(GL_FRAGMENT_SHADER,fs);
        GLuint p=glCreateProgram();glAttachShader(p,v);glAttachShader(p,f);glLinkProgram(p);glDeleteShader(v);glDeleteShader(f);
        GLint ok=0;glGetProgramiv(p,GL_LINK_STATUS,&ok);if(!ok)throw std::runtime_error("Browser output program link");
        GLuint target=0,fbo=0;glGenTextures(1,&target);glActiveTexture(GL_TEXTURE3);glBindTexture(GL_TEXTURE_2D,target);
        glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,b.width*2,b.height,0,GL_RGBA,GL_UNSIGNED_BYTE,nullptr);
        glGenFramebuffers(1,&fbo);glBindFramebuffer(GL_FRAMEBUFFER,fbo);glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,target,0);
        if(glCheckFramebufferStatus(GL_FRAMEBUFFER)!=GL_FRAMEBUFFER_COMPLETE)throw std::runtime_error("Output FBO");
        glViewport(0,0,b.width*2,b.height);glUseProgram(p);glBindVertexArray(b.vao);
        glActiveTexture(GL_TEXTURE0);glBindTexture(GL_TEXTURE_2D,color);glUniform1i(glGetUniformLocation(p,"color"),0);
        glActiveTexture(GL_TEXTURE1);glBindTexture(GL_TEXTURE_2D,near?b.find(token).alpha:0);glUniform1i(glGetUniformLocation(p,"depth"),1);
        glUniform4fv(glGetUniformLocation(p,"content"),1,b.content_rect.data());
        glUniform1f(glGetUniformLocation(p,"shift"),near&&!packed?.0175f*strength:0.f);glUniform1f(glGetUniformLocation(p,"convergence"),convergence);
        glUniform1i(glGetUniformLocation(p,"stereo_pair"),packed?1:0);
        glActiveTexture(GL_TEXTURE2);glBindTexture(GL_TEXTURE_2D,mask);glUniform1i(glGetUniformLocation(p,"matte_map"),2);
        glUniform1i(glGetUniformLocation(p,"matte_enabled"),matte?1:0);glUniform4fv(glGetUniformLocation(p,"matte_content"),1,rect);
        glDrawArrays(GL_TRIANGLES,0,3);glFinish();glPixelStorei(GL_PACK_ALIGNMENT,1);
        glReadPixels(0,0,b.width*2,b.height,GL_RGBA,GL_UNSIGNED_BYTE,rgba);
        if(glGetError()!=GL_NO_ERROR)throw std::runtime_error("Output GL error");
        glUseProgram(0);glBindFramebuffer(GL_FRAMEBUFFER,0);
        glDeleteFramebuffers(1,&fbo);glDeleteTextures(1,&target);if(mask)glDeleteTextures(1,&mask);glDeleteProgram(p);return 1;
    } catch(const std::exception& e) {host::last_error=e.what();return 0;}
}
