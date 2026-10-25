#include "live_capture_core.h"
#include "live_capture.h"
#include <mpv/quest_capture.h>
#include <jni.h>
#include <dlfcn.h>
#include <shared_mutex>
#include <android/log.h>

namespace quest::live {
class Manager {
    std::shared_mutex taps_mutex;
    std::mutex jobs_mutex;
    std::unordered_map<uint64_t,std::shared_ptr<Tap>> taps;
    std::unordered_map<int64_t,std::shared_ptr<Session>> jobs;
    std::shared_mutex audio_gate;
    std::shared_ptr<Session> active;
    uint64_t recording_owner=0;
    std::atomic<uint64_t> missed_owner{0};
    int64_t serial=0;
    struct History {std::atomic<uint64_t> owner{0},layout{0};mpv_handle* core=nullptr;PresentedAudio audio;int64_t last_submit=0,last_report=0,awaiting=0;};
    std::array<History,8> histories{};
public:
    void add(uint64_t owner,mpv_handle* core){
        std::unique_lock<std::shared_mutex> lock(taps_mutex);taps[owner]=std::make_shared<Tap>();
        for(auto& history:histories)if(history.owner.load()==0){history.audio.reset();history.core=core;history.layout.store(0);history.last_submit=history.last_report=history.awaiting=0;history.owner.store(owner);return;}
    }
    std::shared_ptr<Tap> tap(uint64_t owner,bool realtime=false) {
        std::shared_lock<std::shared_mutex> lock(taps_mutex,std::defer_lock);
        if(realtime){if(!lock.try_lock())return {};}else lock.lock();
        auto found=taps.find(owner);return found==taps.end()?nullptr:found->second;
    }
    void remove(uint64_t owner) {
        std::lock_guard<std::mutex> lock(jobs_mutex);
        if(recording_owner==owner&&active)stop_locked(active,active->position());
        std::unique_lock<std::shared_mutex> lock2(taps_mutex);taps.erase(owner);
        for(auto& history:histories)if(history.owner.load()==owner){history.audio.reset();history.owner.store(0);}
    }
    void closing(uint64_t owner) {
        std::lock_guard<std::mutex> lock(jobs_mutex);
        for(auto& history:histories)if(history.owner.load()==owner)history.core=nullptr;
    }
    void video(uint64_t owner,int stream,const AVCodecParameters* codec,const AVPacket* packet) noexcept {
        if(!owner)return;
        if(auto value=tap(owner,true)) {
            auto missed=owner;if(missed_owner.compare_exchange_strong(missed,0))value->invalidate();
            value->video(stream,codec,packet);
        }else missed_owner.store(owner);
    }
    void push(Audio& chunk) noexcept {
        { std::shared_lock<std::shared_mutex> lock(audio_gate,std::try_to_lock);
          if(lock.owns_lock()&&active)active->push(chunk); }
    }
    void fail_audio(int code)noexcept{std::shared_lock<std::shared_mutex> lock(audio_gate,std::try_to_lock);if(lock.owns_lock()&&active)active->fail(code);}
    void pcm(uint64_t owner,const void* data,int frames,int rate,int channels,int format,int64_t ns,float gain=1) noexcept {
        if(channels<1||channels>max_audio_channels||format<1||format>3||rate<8000||rate>192000) {
            std::shared_lock<std::shared_mutex> lock(audio_gate,std::try_to_lock);if(lock.owns_lock()&&active)active->fail(2);return;
        }
        const int stride=channels*(format==2?2:4);
        while(frames>0) {
            Audio chunk;chunk.owner=owner;chunk.frames=std::min(frames,audio_frames);chunk.rate=rate;
            chunk.channels=channels;chunk.format=format;chunk.ns=ns;chunk.gain=gain;
            const int size=chunk.frames*stride;std::memcpy(chunk.bytes.data(),data,size);push(chunk);
            data=static_cast<const unsigned char*>(data)+size;frames-=chunk.frames;
            ns+=static_cast<int64_t>(chunk.frames)*1000000000/rate;
        }
    }
    void device(uint64_t owner,const void* data,int frames,int rate,int channels,int format,int64_t frame,int64_t ns)noexcept {
        if(!owner)return;
        History* history=nullptr;
        for(auto& item:histories)if(item.owner.load()==owner){history=&item;break;}
        if(!history){fail_audio(2);return;}
        if(frames==-2){history->audio.discontinuity();return;}
        if(frames<0){history->audio.reset();history->last_submit=history->last_report=history->awaiting=0;return;}
        if(frames==0){
            const auto now=monotonic_ns();history->last_report=now;history->awaiting=0;
            if(ns>now&&rate>0){frame-=av_rescale_rnd(ns-now,rate,1000000000,AV_ROUND_UP);ns=now;}
            history->audio.present(frame,ns,[&](Audio& output){push(output);});return;
        }
        if(channels<1||channels>max_audio_channels||format<1||format>3||rate<8000||rate>192000){fail_audio(2);return;}
        const auto now=monotonic_ns();
        if(now-history->last_submit>300000000)history->awaiting=now;
        if(!history->awaiting&&now-history->last_report>300000000)history->awaiting=now;
        history->last_submit=now;
        if(history->awaiting&&now-history->awaiting>500000000&&now-history->last_report>500000000)fail_audio(4);
        const int stride=channels*(format==2?2:4);
        while(frames>0) {
            Audio chunk;chunk.owner=owner;chunk.frames=std::min(frames,audio_frames);chunk.rate=rate;
            chunk.channels=channels;chunk.format=format;
            const auto layout=history->layout.load();
            if(av_popcount64(layout)==channels)chunk.layout=layout;
            std::memcpy(chunk.bytes.data(),data,chunk.frames*stride);
            if(!history->audio.submit(chunk,frame)){fail_audio(1);history->audio.reset();}
            frames-=chunk.frames;frame+=chunk.frames;data=static_cast<const unsigned char*>(data)+chunk.frames*stride;
        }
    }
    int64_t start(uint64_t owner,const std::string& path,int64_t position,bool playing) {
        std::lock_guard<std::mutex> lock(jobs_mutex);
        if(active)throw std::runtime_error("Capture is busy");
        auto source=tap(owner);if(!source)throw std::runtime_error("Capture source unavailable");
        uint64_t mask=3;
        // Property access and layout parsing happen once on the clip worker.
        // remove() shares jobs_mutex, so the borrowed core stays alive here.
        for(auto& history:histories)if(history.owner.load()==owner) {
            if(!history.core)throw std::runtime_error("Capture source unavailable");
            char* raw=mpv_get_property_string(history.core,"audio-out-params/channels");
            if(!raw||!*raw){mpv_free(raw);raw=mpv_get_property_string(history.core,"audio-params/channels");}
            if(raw&&*raw) {
                AVChannelLayout layout{};
                const int parsed=av_channel_layout_from_string(&layout,raw);
                const auto actual=parsed>=0&&layout.order==AV_CHANNEL_ORDER_NATIVE?layout.u.mask:uint64_t(0);
                av_channel_layout_uninit(&layout);mpv_free(raw);raw=nullptr;
                if(!actual||av_popcount64(actual)>max_audio_channels||actual>UINT32_MAX)
                    throw std::runtime_error("Capture audio format unavailable");
                history.layout.store(actual);
                if(av_popcount64(actual)>1)mask=actual;
            }
            mpv_free(raw);break;
        }
        const auto ns=monotonic_ns();
        auto session=source->start(position,ns,playing,path,mask);
        {std::unique_lock<std::shared_mutex> gate(audio_gate);active=session;recording_owner=owner;}
        jobs[++serial]=session;return serial;
    }
    std::shared_ptr<Session> get(int64_t id){std::lock_guard<std::mutex> lock(jobs_mutex);auto found=jobs.find(id);return found==jobs.end()?nullptr:found->second;}
    void stop_locked(const std::shared_ptr<Session>& session,int64_t position,int64_t ns=monotonic_ns()) {
        if(active!=session)return;
        if(auto source=tap(recording_owner))source->detach();
        {std::unique_lock<std::shared_mutex> gate(audio_gate);active.reset();recording_owner=0;}
        session->stop(position,ns);
    }
    void stop(int64_t id,int64_t position,int64_t ns) {std::lock_guard<std::mutex> lock(jobs_mutex);auto found=jobs.find(id);if(found!=jobs.end())stop_locked(found->second,position,ns);}
    void forget(int64_t id) {
        std::shared_ptr<Session> old;
        {std::lock_guard<std::mutex> lock(jobs_mutex);auto found=jobs.find(id);if(found==jobs.end())return;
         old=found->second;stop_locked(old,old->begin_us);jobs.erase(found);}
        // Session destructor joins its private writer, on the export worker only.
    }
};
Manager& manager(){static auto* value=new Manager;return *value;}
bool supported(){auto api=reinterpret_cast<uint32_t(*)()>(dlsym(RTLD_DEFAULT,"mpv_quest_capture_api_version"));return api&&api()==QUEST_MPV_CAPTURE_API_VERSION;}
uint64_t source_open(mpv_handle* core) noexcept {
    try {
    if(!supported())return 0;
    (void)manager(); // Allocate bounded history before any real-time callback is installed.
    static std::once_flag once;
    std::call_once(once,[]{
        auto observe=reinterpret_cast<decltype(&mpv_quest_capture_observe)>(dlsym(RTLD_DEFAULT,"mpv_quest_capture_observe"));
        observe([](void*,uint64_t owner,int stream,const AVCodecParameters* codec,const AVPacket* packet){manager().video(owner,stream,codec,packet);},
            [](void*,uint64_t owner,const void* data,int frames,int rate,int channels,int format,int64_t frame,int64_t ns){manager().device(owner,data,frames,rate,channels,format,frame,ns);},nullptr);
    });
    auto owner=reinterpret_cast<decltype(&mpv_quest_capture_owner)>(dlsym(RTLD_DEFAULT,"mpv_quest_capture_owner"))(core);
    manager().add(owner,core);return owner;
    } catch(...) {return 0;}
}
void source_closing(uint64_t owner){if(owner)manager().closing(owner);}
void source_close(uint64_t owner){if(owner)manager().remove(owner);}
std::string text(JNIEnv* env,jstring raw){if(!raw)return {};const char* p=env->GetStringUTFChars(raw,nullptr);if(!p)throw std::bad_alloc();std::string out(p);env->ReleaseStringUTFChars(raw,p);return out;}
}
extern "C" JNIEXPORT jboolean JNICALL Java_org_vrpassthroughplayer_plugin_LiveCaptureNative_supported(JNIEnv*,jclass){return quest::live::supported();}
extern "C" JNIEXPORT jlong JNICALL Java_org_vrpassthroughplayer_plugin_LiveCaptureNative_start(JNIEnv* env,jclass,jlong owner,jstring path,jlong us,jboolean playing){try{return quest::live::manager().start(owner,quest::live::text(env,path),us,playing);}catch(...){return 0;}}
extern "C" JNIEXPORT void JNICALL Java_org_vrpassthroughplayer_plugin_LiveCaptureNative_clock(JNIEnv*,jclass,jlong id,jlong us,jboolean playing){if(auto s=quest::live::manager().get(id))s->clock(quest::live::monotonic_ns(),us,playing);}
extern "C" JNIEXPORT void JNICALL Java_org_vrpassthroughplayer_plugin_LiveCaptureNative_limit(JNIEnv*,jclass,jlong id,jlong us,jlong ns){if(auto s=quest::live::manager().get(id))s->limit(us,ns);}
extern "C" JNIEXPORT void JNICALL Java_org_vrpassthroughplayer_plugin_LiveCaptureNative_cancel(JNIEnv*,jclass,jlong id){if(auto s=quest::live::manager().get(id))s->cancel();}
extern "C" JNIEXPORT void JNICALL Java_org_vrpassthroughplayer_plugin_LiveCaptureNative_stop(JNIEnv*,jclass,jlong id,jlong us,jlong ns){quest::live::manager().stop(id,us,ns);}
extern "C" JNIEXPORT jstring JNICALL Java_org_vrpassthroughplayer_plugin_LiveCaptureNative_status(JNIEnv* env,jclass,jlong id){auto s=quest::live::manager().get(id);return env->NewStringUTF(s?s->status().c_str():"{\"state\":\"error\",\"error\":\"Capture source unavailable\"}");}
extern "C" JNIEXPORT void JNICALL Java_org_vrpassthroughplayer_plugin_LiveCaptureNative_forget(JNIEnv*,jclass,jlong id){quest::live::manager().forget(id);}
extern "C" JNIEXPORT jint JNICALL Java_org_vrpassthroughplayer_plugin_LiveCaptureNative_exportProgress(JNIEnv*,jclass,jlong id){auto s=quest::live::manager().get(id);return s?s->export_percent():0;}
extern "C" JNIEXPORT jstring JNICALL Java_org_vrpassthroughplayer_plugin_LiveCaptureNative_export(JNIEnv* env,jclass,jlong id,jstring output,jstring mode){
    auto s=quest::live::manager().get(id);std::string result="{\"state\":\"error\",\"error\":\"Capture save failed\"}";
    if(s&&s->audio_duration()<=0)result="{\"state\":\"error\",\"error\":\"Recording is empty\"}";
    else if(s&&s->done()&&s->status().find("\"ready\"")!=std::string::npos){
        try{result=s->export_file(quest::live::text(env,output),quest::live::text(env,mode));}catch(...){}}
    if(s&&!result.empty()&&result.back()=='}'){result.pop_back();result+=",\"capture_metrics\":"+s->metrics()+"}";}
    return env->NewStringUTF(result.c_str());
}
extern "C" JNIEXPORT void JNICALL Java_org_vrpassthroughplayer_plugin_LiveCaptureNative_narration(JNIEnv* env,jclass,jfloatArray pcm,jint count,jlong ns,jfloat gain){
    if(count<0||count>quest::live::audio_frames*2||count%2||count>env->GetArrayLength(pcm))return;
    std::array<float,quest::live::audio_frames*2> data{};env->GetFloatArrayRegion(pcm,0,count,data.data());
    quest::live::manager().pcm(UINT64_MAX,data.data(),count/2,48000,2,1,ns,gain);
}
