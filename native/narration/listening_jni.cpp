#include "jni_text.h"
#include "moonshine-c-api.h"
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <limits>
#include <memory>
#include <mutex>
#include <sstream>
#include <stdexcept>
#include <unordered_map>
#include <vector>
extern "C" {
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libswresample/swresample.h>
}

namespace {
struct ListeningReadAt {
    virtual ~ListeningReadAt()=default;
    virtual int64_t size() const=0;
    virtual int read(int64_t offset,uint8_t* bytes,int count)=0;
};
// The Java object owns only one reader of the existing lease. Its cache and
// account lifetime remain with the player; no second HTTP producer runs ahead.
struct ListeningJavaInput final:ListeningReadAt {
    JavaVM* vm=nullptr;jobject object=nullptr;jbyteArray buffer=nullptr;
    jmethodID readMethod=nullptr,closeMethod=nullptr;int64_t length=0;
    struct Environment {
        JavaVM* vm;JNIEnv* env=nullptr;bool attached=false;
        explicit Environment(JavaVM* value):vm(value){
            if(vm->GetEnv(reinterpret_cast<void**>(&env),JNI_VERSION_1_6)==JNI_EDETACHED){
                attached=vm->AttachCurrentThread(&env,nullptr)==JNI_OK;
            }
        }
        ~Environment(){if(attached)vm->DetachCurrentThread();}
    };
    ListeningJavaInput(JNIEnv* env,jobject input){
        env->GetJavaVM(&vm);object=env->NewGlobalRef(input);
        auto type=env->GetObjectClass(input);
        readMethod=env->GetMethodID(type,"readAt","(J[B)I");closeMethod=env->GetMethodID(type,"close","()V");
        auto sizeMethod=env->GetMethodID(type,"size","()J");env->DeleteLocalRef(type);
        auto local=env->NewByteArray(64*1024);buffer=static_cast<jbyteArray>(env->NewGlobalRef(local));env->DeleteLocalRef(local);
        if(sizeMethod)length=env->CallLongMethod(input,sizeMethod);
        if(env->ExceptionCheck())env->ExceptionClear();
    }
    ~ListeningJavaInput()override{
        Environment scope(vm);auto* env=scope.env;if(!env)return;
        if(object&&closeMethod){env->CallVoidMethod(object,closeMethod);if(env->ExceptionCheck())env->ExceptionClear();}
        if(buffer)env->DeleteGlobalRef(buffer);if(object)env->DeleteGlobalRef(object);
    }
    int64_t size()const override{return length;}
    int read(int64_t offset,uint8_t* bytes,int count)override{
        Environment scope(vm);auto* env=scope.env;
        if(!env||!object||!buffer||!readMethod)return AVERROR(EIO);
        // A Java array is exactly the requested length, so the source cannot
        // speculate to 64 KiB merely because a packet is a few hundred bytes.
        const int wanted=std::min(count,64*1024);
        auto target=wanted==64*1024?buffer:env->NewByteArray(wanted);
        if(!target){if(env->ExceptionCheck())env->ExceptionClear();return AVERROR(ENOMEM);}
        int n=env->CallIntMethod(object,readMethod,jlong(offset),target);
        if(env->ExceptionCheck()){env->ExceptionClear();n=AVERROR(EIO);}
        if(n>0&&n<=wanted)env->GetByteArrayRegion(target,0,n,reinterpret_cast<jbyte*>(bytes));
        else if(n>0)n=AVERROR(EIO);
        if(target!=buffer)env->DeleteLocalRef(target);
        if(env->ExceptionCheck()){env->ExceptionClear();return AVERROR(EIO);}
        return n==-1?AVERROR_EOF:n;
    }
};
// Uses the same FFmpeg, timestamp origin, TLS and disc rules as voice_scan.cpp.
// One persistent audio-only decoder; never opens a second video decoder.
struct AudioReader {
    AVFormatContext* format=nullptr;
    AVCodecContext* codec=nullptr;
    SwrContext* swr=nullptr;
    AVFrame* frame=av_frame_alloc();
    AVPacket* packet=av_packet_alloc();
    std::unique_ptr<ListeningReadAt> input;
    AVIOContext* io=nullptr;int64_t ioPosition=0;
    std::atomic<bool>* cancelled;
    std::chrono::steady_clock::time_point deadline;
    int index=-1,anchor=-1;
    double origin=0, start=0, next=std::numeric_limits<double>::quiet_NaN();
    int64_t cursor=0, pendingAt=0;
    size_t pendingUsed=0;
    std::vector<float> pending;
    bool draining=false, eof=false, yieldingRead=false;
    explicit AudioReader(std::atomic<bool>* flag):cancelled(flag) {}
    ~AudioReader(){av_frame_free(&frame);av_packet_free(&packet);swr_free(&swr);avcodec_free_context(&codec);avformat_close_input(&format);if(io){av_freep(&io->buffer);avio_context_free(&io);}}
    static int readInput(void* opaque,uint8_t* bytes,int count){
        auto* reader=static_cast<AudioReader*>(opaque);
        if(interrupt(reader))return AVERROR_EXIT;
        if(reader->ioPosition>=reader->input->size())return AVERROR_EOF;
        int n=reader->input->read(reader->ioPosition,bytes,count);
        if(interrupt(reader))return AVERROR_EXIT;
        if(n>0)reader->ioPosition+=n;return n==0?AVERROR(EIO):n;
    }
    static int64_t seekInput(void* opaque,int64_t offset,int whence){
        auto* reader=static_cast<AudioReader*>(opaque);
        if(whence==AVSEEK_SIZE)return reader->input->size();
        whence&=~AVSEEK_FORCE;
        const int64_t base=whence==SEEK_SET?0:whence==SEEK_CUR?reader->ioPosition:whence==SEEK_END?reader->input->size():-1;
        if(base<0||offset < -base||offset > reader->input->size()-base)return AVERROR(EINVAL);
        return reader->ioPosition=base+offset;
    }
    static int interrupt(void* opaque) {
        auto* reader=static_cast<AudioReader*>(opaque);
        return reader->cancelled->load() || (!reader->yieldingRead&&std::chrono::steady_clock::now()>reader->deadline);
    }
    void check(){if(interrupt(this))throw std::runtime_error("listening_cancelled");}
    void open(std::string path,const std::string& ca,int track,double at,bool disc,int playlist,
              double mediaOrigin=std::numeric_limits<double>::quiet_NaN(),bool directAudio=true,
              std::unique_ptr<ListeningReadAt> directInput={}) {
        // A cloud origin permits 15 s to connect and 20 s per read. Its indexed
        // header must not be cut off at an earlier 15 s whole-open deadline.
        // The operation stays on the cancellable worker; UI hold is still 45 s.
        deadline=std::chrono::steady_clock::now()+std::chrono::seconds(directInput?30:15);
        if(!frame||!packet||!std::isfinite(at)||at<0||track<0||playlist < -1||playlist>99999)throw std::runtime_error("listening_input");
        format=avformat_alloc_context();if(!format)throw std::runtime_error("listening_allocation");
        input=std::move(directInput);
        if(input){
            if(input->size()<=0)throw std::runtime_error("listening_input");
            auto* bytes=static_cast<uint8_t*>(av_malloc(32*1024));if(!bytes)throw std::runtime_error("listening_allocation");
            io=avio_alloc_context(bytes,32*1024,0,this,readInput,nullptr,seekInput);
            if(!io){av_free(bytes);throw std::runtime_error("listening_allocation");}
            format->pb=io;format->flags|=AVFMT_FLAG_CUSTOM_IO;
        }
        format->interrupt_callback={interrupt,this};
        format->probesize=2*1024*1024;format->max_analyze_duration=3*AV_TIME_BASE;
        AVDictionary* options=nullptr;
        av_dict_set(&options,"rw_timeout","8000000",0);av_dict_set(&options,"tls_verify","1",0);
        av_dict_set(&options,"protocol_whitelist","file,http,https,tcp,tls,crypto",0);
        av_dict_set(&options,"user_agent","Thru3D audio reader",0);
        if(!ca.empty())av_dict_set(&options,"ca_file",ca.c_str(),0);
        if(path.rfind("fd://",0)==0)path="/proc/self/fd/"+path.substr(5);
        const AVInputFormat* demuxer=disc?av_find_input_format("bd_mvc"):nullptr;
        if(disc&&!demuxer){av_dict_free(&options);throw std::runtime_error("listening_disc");}
        if(disc)av_dict_set_int(&options,"playlist",playlist,0);
        int opened=avformat_open_input(&format,path.c_str(),demuxer,&options);av_dict_free(&options);
        if(opened<0)throw std::runtime_error("listening_open:"+std::to_string(opened));
        // The player's demuxer already established the media origin. Reusing it
        // preserves delayed audio and nonzero timestamps without probing video
        // again. Standalone readers still need FFmpeg's normal timing probe.
        auto* described=unsigned(track)<format->nb_streams?format->streams[track]->codecpar:nullptr;
        if(!std::isfinite(mediaOrigin)||!described||described->codec_id==AV_CODEC_ID_NONE||
           described->sample_rate<=0||described->ch_layout.nb_channels<=0){
            std::vector<AVDictionary*> probeOptions(format->nb_streams,nullptr);
            for(auto& options:probeOptions)av_dict_set(&options,"threads","1",0);
            const int info=avformat_find_stream_info(format,probeOptions.data());
            for(auto& options:probeOptions)av_dict_free(&options);
            if(info<0)throw std::runtime_error("listening_probe:"+std::to_string(info));
        }
        check();index=track;start=at;
        if(unsigned(index)>=format->nb_streams||format->streams[index]->codecpar->codec_type!=AVMEDIA_TYPE_AUDIO)throw std::runtime_error("listening_audio_track");
        auto* parameters=format->streams[index]->codecpar;
        auto* decoder=avcodec_find_decoder(parameters->codec_id);
        if(!decoder)throw std::runtime_error("listening_decoder");
        codec=avcodec_alloc_context3(decoder);
        if(!codec||avcodec_parameters_to_context(codec,parameters)<0)throw std::runtime_error("listening_decoder");
        codec->thread_count=1;
        if(avcodec_open2(codec,decoder,nullptr)<0)throw std::runtime_error("listening_decoder");
        origin=std::isfinite(mediaOrigin)?mediaOrigin:(format->start_time==AV_NOPTS_VALUE?0:format->start_time/double(AV_TIME_BASE));
        for(unsigned i=0;i<format->nb_streams;++i)if(int(i)!=index)format->streams[i]->discard=AVDISCARD_ALL;
        anchor=index;
        const bool indexed=format->iformat&&std::string(format->iformat->name).find("mov")!=std::string::npos;
        // MOV tunes AVIO for alternating video/audio (multi-MiB read-through
        // seeks). This consumer only needs audio: don't download discarded
        // video again just to cross a gap between indexed audio packets.
        if(directAudio&&indexed&&format->pb&&(input||path.rfind("http",0)==0))format->pb->direct=1;
        if(!indexed)for(unsigned i=0;i<format->nb_streams;++i)if(format->streams[i]->codecpar->codec_type==AVMEDIA_TYPE_VIDEO){anchor=int(i);format->streams[i]->discard=AVDISCARD_DEFAULT;break;}
        auto stamp=int64_t(std::llround((start+origin)/av_q2d(format->streams[anchor]->time_base)));
        if(avformat_seek_file(format,anchor,INT64_MIN,stamp,stamp,AVSEEK_FLAG_BACKWARD)<0&&start>.001)throw std::runtime_error("listening_seek");
        avcodec_flush_buffers(codec);
    }
    bool framePcm() {
        for(int packets=0;packets<200000;++packets){
            check();
            if(yieldingRead&&std::chrono::steady_clock::now()>deadline)return false;
            int received=avcodec_receive_frame(codec,frame);
            if(received==AVERROR_EOF){
                // Drain the resampler tail instead of losing the final phoneme.
                if(swr){float tail[256];auto* output=reinterpret_cast<uint8_t*>(tail);int n=swr_convert(swr,&output,256,nullptr,0);
                    if(n>0){pending.assign(tail,tail+n);pendingUsed=0;pendingAt=int64_t(std::llround((next-start)*16000));next+=n/16000.;return true;}}
                eof=true;return false;
            }
            if(received==0){
                double at=frame->best_effort_timestamp==AV_NOPTS_VALUE?next:frame->best_effort_timestamp*av_q2d(format->streams[index]->time_base)-origin;
                if(!std::isfinite(at)||frame->sample_rate<=0)throw std::runtime_error("listening_timestamp");
                if(!swr){AVChannelLayout mono=AV_CHANNEL_LAYOUT_MONO;
                    if(swr_alloc_set_opts2(&swr,&mono,AV_SAMPLE_FMT_FLT,16000,&frame->ch_layout,AVSampleFormat(frame->format),frame->sample_rate,0,nullptr)<0||swr_init(swr)<0)throw std::runtime_error("listening_resample");}
                at-=swr_get_delay(swr,frame->sample_rate)/double(frame->sample_rate);
                int count=int(av_rescale_rnd(swr_get_delay(swr,frame->sample_rate)+frame->nb_samples,16000,frame->sample_rate,AV_ROUND_UP));
                if(count<0||count>192000)throw std::runtime_error("listening_frame_limit");
                pending.resize(count);auto* output=reinterpret_cast<uint8_t*>(pending.data());
                count=swr_convert(swr,&output,count,const_cast<const uint8_t**>(frame->extended_data),frame->nb_samples);
                if(count<0)throw std::runtime_error("listening_resample");
                pending.resize(count);pendingUsed=0;pendingAt=int64_t(std::llround((at-start)*16000));next=at+count/16000.;
                av_frame_unref(frame);return true;
            }
            if(received!=AVERROR(EAGAIN)||draining)throw std::runtime_error("listening_decode");
            int read=av_read_frame(format,packet);
            if(read==AVERROR_EOF){if(avcodec_send_packet(codec,nullptr)<0)throw std::runtime_error("listening_decode");draining=true;continue;}
            if(read<0)throw std::runtime_error("listening_read:"+std::to_string(read));
            if(anchor!=index&&packet->stream_index==anchor)format->streams[anchor]->discard=AVDISCARD_ALL;
            int sent=packet->stream_index==index?avcodec_send_packet(codec,packet):0;
            av_packet_unref(packet);if(sent<0)throw std::runtime_error("listening_decode");
        }
        throw std::runtime_error("listening_packet_limit");
    }
    std::vector<float> read() {
        deadline=std::chrono::steady_clock::now()+std::chrono::seconds(12);
        // The shared cloud reader already bounds each network read. Expiring
        // the step while a successful read returns discards valid packet bytes
        // and poisons AVIO with EXIT. Yield between packets instead, preserving
        // decoder/PCM state for the next step. Explicit cancellation stays hard.
        yieldingRead=input!=nullptr;
        struct Reset {bool& flag;~Reset(){flag=false;}} reset{yieldingRead};
        std::vector<float> result;result.reserve(16000);
        while(result.size()<16000){
            check();
            if(yieldingRead&&std::chrono::steady_clock::now()>deadline)break;
            if(pendingUsed>=pending.size()){if(eof||!framePcm())break;if(pending.empty())continue;}
            int64_t at=pendingAt+int64_t(pendingUsed);
            if(at<cursor){pendingUsed+=size_t(std::min(cursor-at,int64_t(pending.size()-pendingUsed)));continue;}
            if(at>cursor){size_t n=size_t(std::min(at-cursor,int64_t(16000-result.size())));result.insert(result.end(),n,0);cursor+=n;continue;}
            size_t n=std::min(pending.size()-pendingUsed,16000-result.size());
            result.insert(result.end(),pending.begin()+pendingUsed,pending.begin()+pendingUsed+n);pendingUsed+=n;cursor+=int64_t(n);
        }
        return result;
    }
    std::vector<jlong> audioSpans() const {
        std::vector<jlong> spans;
        if(!format||index<0||!format->iformat||std::string(format->iformat->name).find("mov")==std::string::npos)return spans;
        auto* stream=format->streams[index];const int count=avformat_index_get_entries_count(stream);
        if(count<=0||count>1000000)return spans;
        for(int i=0;i<count;++i){
            const auto* entry=avformat_index_get_entry(stream,i);
            if(!entry||entry->pos<0||entry->size<=0||entry->pos>INT64_MAX-entry->size)return {};
            const auto end=entry->pos+entry->size;
            if(!spans.empty()&&entry->pos<spans.back())return {};
            if(!spans.empty()&&entry->pos==spans.back()&&end-spans[spans.size()-2]<=64*1024)spans.back()=end;
            else {if(spans.size()>=400000)return {};spans.push_back(entry->pos);spans.push_back(end);}
        }
        return spans;
    }
};
struct Engine {
#ifdef __ANDROID__
    struct EnvironmentLease {
        void* value;
        EnvironmentLease();
        ~EnvironmentLease();
    } environment;
#endif
    int model=-1,stream=-1;
    std::atomic<bool> cancelled{false};
    std::unique_ptr<AudioReader> reader;
    double offset=0;
    bool stopped=false;
    uint64_t emitted=0;
    ~Engine(){if(stream>=0)moonshine_free_stream(model,stream);if(model>=0)moonshine_free_transcriber(model);}
};
#ifdef __ANDROID__
extern "C" void* thru3d_ort_acquire();
extern "C" void thru3d_ort_release(void* lease);
Engine::EnvironmentLease::EnvironmentLease():value(thru3d_ort_acquire()) {}
Engine::EnvironmentLease::~EnvironmentLease(){thru3d_ort_release(value);}
#endif
std::mutex registryMutex;
std::unordered_map<int64_t,std::shared_ptr<Engine>> engines;
int64_t serial=0;
std::shared_ptr<Engine> engine(int64_t id){std::lock_guard<std::mutex> guard(registryMutex);auto it=engines.find(id);if(it==engines.end())throw std::runtime_error("listening_handle");return it->second;}
void ok(int value){if(value<0)throw std::runtime_error("listening_inference");}
std::string quote(const char* value){std::string out="\"";for(auto p=reinterpret_cast<const unsigned char*>(value?value:"");*p;++p){if(*p=='"'||*p=='\\')out+='\\';if(*p>=32)out+=char(*p);else if(*p=='\n')out+="\\n";}return out+'"';}
jstring utf8(JNIEnv* env,const std::string& value){auto bytes=env->NewByteArray(jsize(value.size()));env->SetByteArrayRegion(bytes,0,jsize(value.size()),reinterpret_cast<const jbyte*>(value.data()));auto type=env->FindClass("java/lang/String");auto charset=env->NewStringUTF("UTF-8");auto text=static_cast<jstring>(env->NewObject(type,env->GetMethodID(type,"<init>","([BLjava/lang/String;)V"),bytes,charset));env->DeleteLocalRef(bytes);env->DeleteLocalRef(charset);env->DeleteLocalRef(type);return text;}
int listeningLoadModel(const char* path,const std::string& language,const char* vadThreshold="0.65"){
    moonshine_option_t options[]={{"ort_providers","CPUExecutionProvider"},{"identify_speakers","false"},{"return_audio_data","false"},
        {"max_tokens_per_second",language=="en"?"6.5":"13"},{"vad_max_segment_duration","6"},{"decode_incomplete_lines","false"},
        // Film music/room noise must not be treated as low-confidence speech.
        // Reuse Moonshine's existing VAD; no extra model or inference pass.
        {"vad_threshold",vadThreshold}};
    return moonshine_load_transcriber_from_files(path,MOONSHINE_MODEL_ARCH_TINY_STREAMING,options,
        sizeof(options)/sizeof(options[0]),MOONSHINE_HEADER_VERSION);
}
}
extern "C" JNIEXPORT jlong JNICALL Java_org_vrpassthroughplayer_plugin_ListeningNative_create(JNIEnv* env,jclass,jstring directory,jstring language){
    try{auto e=std::make_shared<Engine>();auto lang=narration_utf8(env,language);
        auto path=narration_utf8(env,directory);
        e->model=listeningLoadModel(path.c_str(),lang);ok(e->model);
        std::lock_guard<std::mutex> guard(registryMutex);auto id=++serial;engines[id]=e;return id;
    }catch(const std::exception&){narration_error(env,"listening_model_error");return 0;}
}
static void listening_open(JNIEnv* env,jlong id,jstring path,jint track,jstring ca,jdouble start,jboolean disc,jint playlist,double origin,bool directAudio=true,jobject input=nullptr){
    try{auto e=engine(id);if(e->cancelled)throw std::runtime_error("listening_cancelled");e->reader.reset();
        if(e->stream>=0){moonshine_free_stream(e->model,e->stream);e->stream=-1;}
        e->reader=std::make_unique<AudioReader>(&e->cancelled);
        e->reader->open(narration_utf8(env,path),narration_utf8(env,ca),track,start,disc==JNI_TRUE,playlist,origin,directAudio,
                        input?std::make_unique<ListeningJavaInput>(env,input):nullptr);
        e->offset=start;e->stream=moonshine_create_stream(e->model,0);ok(e->stream);ok(moonshine_start_stream(e->model,e->stream));e->stopped=false;e->emitted=0;
    }catch(const std::exception& error){narration_error(env,error.what());}
}
extern "C" JNIEXPORT void JNICALL Java_org_vrpassthroughplayer_plugin_ListeningNative_open(JNIEnv* env,jclass,jlong id,jstring path,jint track,jstring ca,jdouble start,jboolean disc,jint playlist){
    listening_open(env,id,path,track,ca,start,disc,playlist,std::numeric_limits<double>::quiet_NaN());
}
extern "C" JNIEXPORT void JNICALL Java_org_vrpassthroughplayer_plugin_ListeningNative_openWithClock(JNIEnv* env,jclass,jlong id,jstring path,jint track,jstring ca,jdouble start,jboolean disc,jint playlist,jdouble origin,jboolean directAudio,jobject input){
    listening_open(env,id,path,track,ca,start,disc,playlist,origin,directAudio==JNI_TRUE,input);
}
static std::string listening_step(const std::shared_ptr<Engine>& e){
    if(!e->reader||e->cancelled)throw std::runtime_error("listening_cancelled");
        const auto began=std::chrono::steady_clock::now();
        auto pcm=e->reader->read();
        const auto decoded=std::chrono::steady_clock::now();
        if(!pcm.empty())ok(moonshine_transcribe_add_audio_to_stream(e->model,e->stream,pcm.data(),pcm.size(),16000,0));
        if(e->reader->eof&&!e->stopped){ok(moonshine_stop_stream(e->model,e->stream));e->stopped=true;}
        transcript_t* transcript=nullptr;ok(moonshine_transcribe_stream(e->model,e->stream,0,&transcript));
        if(e->cancelled)throw std::runtime_error("listening_cancelled");
        const double through=e->reader->start+e->reader->cursor/16000.;
        // Do not certify a time range while speech spanning it can still finish.
        // The configured VAD cap is 6s; retain 8s for input/VAD look-behind too.
        double settled=e->stopped?through:std::max(e->offset,through-8.0);
        if(!e->stopped&&transcript&&transcript->line_count){const auto& last=transcript->lines[transcript->line_count-1];
            if(!last.is_complete&&std::isfinite(last.start_time))settled=std::min(settled,e->offset+last.start_time);}
        const auto recognized=std::chrono::steady_clock::now();
        const auto* audioStream=e->reader->format->streams[e->reader->index];
        const double audioEnd=audioStream->duration==AV_NOPTS_VALUE?0:
            (audioStream->duration+(audioStream->start_time==AV_NOPTS_VALUE?0:audioStream->start_time))*av_q2d(audioStream->time_base)-e->reader->origin;
        std::ostringstream json;json.precision(12);json<<"{\"through\":"<<through<<",\"settled\":"<<settled<<",\"eof\":"<<(e->stopped?"true":"false")
            <<",\"audio_end\":"<<audioEnd
            <<",\"duration\":"<<(e->reader->format->duration==AV_NOPTS_VALUE?0:e->reader->format->duration/double(AV_TIME_BASE))
            <<",\"read_ms\":"<<std::chrono::duration<double,std::milli>(decoded-began).count()
            <<",\"inference_ms\":"<<std::chrono::duration<double,std::milli>(recognized-decoded).count()<<",\"cues\":[";bool first=true;
        if(transcript)for(uint64_t i=e->emitted;i<transcript->line_count;++i){auto& line=transcript->lines[i];
            if(!line.is_complete)break;
            e->emitted=i+1;
            if(!line.text||!line.text[0]||!std::isfinite(line.start_time)||!std::isfinite(line.duration)||line.duration<=0)continue;
            double begin=e->offset+line.start_time,end=std::min(through,begin+line.duration);
            if(end<=begin)continue;
            if(!first)json<<',';first=false;json<<"{\"start\":"<<begin<<",\"end\":"<<end<<",\"text\":"<<quote(line.text)<<'}';
        }
        json<<"]}";
        return json.str();
}
extern "C" JNIEXPORT jstring JNICALL Java_org_vrpassthroughplayer_plugin_ListeningNative_step(JNIEnv* env,jclass,jlong id){
    try{return utf8(env,listening_step(engine(id)));}
    catch(const std::exception& error){narration_error(env,error.what());return nullptr;}
}
extern "C" JNIEXPORT jlongArray JNICALL Java_org_vrpassthroughplayer_plugin_ListeningNative_audioSpans(JNIEnv* env,jclass,jlong id){
    try{auto e=engine(id);if(!e->reader||e->cancelled)throw std::runtime_error("listening_cancelled");
        const auto spans=e->reader->audioSpans();auto result=env->NewLongArray(jsize(spans.size()));
        if(result&&!spans.empty())env->SetLongArrayRegion(result,0,jsize(spans.size()),spans.data());return result;
    }catch(const std::exception& error){narration_error(env,error.what());return nullptr;}
}
extern "C" JNIEXPORT void JNICALL Java_org_vrpassthroughplayer_plugin_ListeningNative_cancel(JNIEnv*,jclass,jlong id){try{engine(id)->cancelled=true;}catch(const std::exception&) {}}
extern "C" JNIEXPORT void JNICALL Java_org_vrpassthroughplayer_plugin_ListeningNative_begin(JNIEnv*,jclass,jlong id){try{engine(id)->cancelled=false;}catch(const std::exception&) {}}
extern "C" JNIEXPORT void JNICALL Java_org_vrpassthroughplayer_plugin_ListeningNative_destroy(JNIEnv*,jclass,jlong id){
    std::shared_ptr<Engine> retiring;
    {std::lock_guard<std::mutex> guard(registryMutex);auto it=engines.find(id);if(it!=engines.end()){retiring=std::move(it->second);engines.erase(it);}}
    // FFmpeg closes sockets and ORT joins workers here. Neither may hold the
    // registry lock used by UI-thread cancellation on this or another video.
}
