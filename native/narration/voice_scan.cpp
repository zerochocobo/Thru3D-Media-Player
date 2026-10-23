#include "jni_text.h"
#include "voice_jobs.h"
#include "voice_vad.h"
#include <cmath>
#include <sstream>
#include <vector>
extern "C" {
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libswresample/swresample.h>
}
namespace {
struct Reader {
    AVFormatContext* format=nullptr;AVCodecContext* codec=nullptr;SwrContext* swr=nullptr;
    AVFrame* frame=av_frame_alloc();AVPacket* packet=av_packet_alloc();
    ~Reader(){av_frame_free(&frame);av_packet_free(&packet);swr_free(&swr);avcodec_free_context(&codec);avformat_close_input(&format);}
    void open(JNIEnv* e,jstring input,jstring ca,bool disc,int playlist,VoiceJob* job) {
        if(!frame||!packet)throw std::runtime_error("voice_allocation");
        format=avformat_alloc_context();if(!format)throw std::runtime_error("voice_allocation");
        format->interrupt_callback={VoiceJob::interrupt,job};
        AVDictionary* options=nullptr;
        av_dict_set(&options,"rw_timeout","8000000",0);av_dict_set(&options,"tls_verify","1",0);
        av_dict_set(&options,"protocol_whitelist","file,http,https,tcp,tls,crypto",0);
        av_dict_set(&options,"user_agent","Thru3D voice reader",0);
        auto trust=narration_utf8(e,ca);if(!trust.empty())av_dict_set(&options,"ca_file",trust.c_str(),0);
        auto path=narration_utf8(e,input);if(path.rfind("fd://",0)==0)path="/proc/self/fd/"+path.substr(5);
        const AVInputFormat* demuxer=disc?av_find_input_format("bd_mvc"):nullptr;
        if((disc&&!demuxer)||playlist < -1||playlist>99999){av_dict_free(&options);throw std::runtime_error("voice_disc_unavailable");}
        if(disc)av_dict_set_int(&options,"playlist",playlist,0);
        int result=avformat_open_input(&format,path.c_str(),demuxer,&options);av_dict_free(&options);
        if(result<0)throw std::runtime_error("voice_input_unavailable");
    }
};
std::string quoted(const char* value) {
    std::string out="\"";
    for(const unsigned char* p=reinterpret_cast<const unsigned char*>(value?value:"");*p;++p){
        if(*p=='"'||*p=='\\')out+='\\';
        if(*p>=32)out+=char(*p);
    }
    return out+'"';
}
const char* tag(AVDictionary* metadata,const char* key) {auto* item=av_dict_get(metadata,key,nullptr,0);return item?item->value:"";}
}
extern "C" JNIEXPORT jstring JNICALL Java_org_vrpassthroughplayer_plugin_VoiceCloneNative_probe(JNIEnv* e,jclass,jlong id,jstring path,jstring ca,jboolean disc,jint playlist) {
    try {
        auto job=voice_job(id);Reader a;a.open(e,path,ca,disc==JNI_TRUE,playlist,job.get());
        a.format->probesize=2*1024*1024;a.format->max_analyze_duration=3*AV_TIME_BASE;
        if(avformat_find_stream_info(a.format,nullptr)<0||VoiceJob::interrupt(job.get()))throw std::runtime_error("voice_probe_failed");
        std::ostringstream json;json<<"{\"paused\":\"yes\",\"duration\":"<<(a.format->duration>0?a.format->duration/double(AV_TIME_BASE):0)<<",\"audio_tracks\":[";
        bool first=true;
        for(unsigned i=0;i<a.format->nb_streams;++i){auto* s=a.format->streams[i];if(s->codecpar->codec_type!=AVMEDIA_TYPE_AUDIO)continue;
            if(!first)json<<',';first=false;
            json<<"{\"id\":"<<i+1<<",\"stream_index\":"<<i<<",\"language\":"<<quoted(tag(s->metadata,"language"))<<",\"title\":"<<quoted(tag(s->metadata,"title"))<<'}';
        }
        json<<"]}";return e->NewStringUTF(json.str().c_str());
    }catch(const std::exception&){narration_error(e,"voice_probe_failed");return nullptr;}
}
extern "C" JNIEXPORT void JNICALL Java_org_vrpassthroughplayer_plugin_VoiceCloneNative_scan(JNIEnv* e,jclass,jlong id,jstring input,jint index,jstring ca,jdouble start,jdouble end,jboolean disc,jint playlist,jstring model,jobject listener) {
    try {
        if(!std::isfinite(start)||!std::isfinite(end)||start<0||end<=start||end-start>600.001||index<0||!listener)throw std::runtime_error("voice_scan_range");
        auto job=voice_job(id);job->deadline=std::chrono::steady_clock::now()+std::chrono::minutes(10);
        Reader a;a.open(e,input,ca,disc==JNI_TRUE,playlist,job.get());
        if(unsigned(index)>=a.format->nb_streams)throw std::runtime_error("voice_track_required");
        auto* stream=a.format->streams[index];auto* params=stream->codecpar;
        if(params->codec_type!=AVMEDIA_TYPE_AUDIO)throw std::runtime_error("voice_track_required");
        auto* decoder=avcodec_find_decoder(params->codec_id);if(!decoder)throw std::runtime_error("voice_decoder");
        a.codec=avcodec_alloc_context3(decoder);
        if(!a.codec||avcodec_parameters_to_context(a.codec,params)<0||avcodec_open2(a.codec,decoder,nullptr)<0)throw std::runtime_error("voice_decoder");
        for(unsigned i=0;i<a.format->nb_streams;++i)if(int(i)!=index)a.format->streams[i]->discard=AVDISCARD_ALL;
        const bool indexed=a.format->iformat&&std::string(a.format->iformat->name).find("mov")!=std::string::npos;
        int anchor=index;
        if(!indexed)for(unsigned i=0;i<a.format->nb_streams;++i)if(a.format->streams[i]->codecpar->codec_type==AVMEDIA_TYPE_VIDEO){anchor=int(i);a.format->streams[i]->discard=AVDISCARD_DEFAULT;break;}
        const double origin=a.format->start_time==AV_NOPTS_VALUE?0:a.format->start_time/double(AV_TIME_BASE);
        const auto stamp=int64_t(std::llround((start+origin)/av_q2d(a.format->streams[anchor]->time_base)));
        if(avformat_seek_file(a.format,anchor,INT64_MIN,stamp,stamp,AVSEEK_FLAG_BACKWARD)<0)throw std::runtime_error("voice_seek_failed");
        avcodec_flush_buffers(a.codec);
        VoiceVad vad(narration_utf8(e,model).c_str());
        auto cls=e->GetObjectClass(listener);auto callback=e->GetMethodID(cls,"frames","(D[F[F[FZ)Z");e->DeleteLocalRef(cls);
        if(!callback)throw std::runtime_error("voice_callback");
        std::array<float,512> block{};int used=0;int64_t cursor=0;
        const int64_t wanted=int64_t(std::llround((end-start)*16000));
        std::vector<float> probabilities,levels,peaks;double batchStart=start;bool keep=true,eof=false;
        auto deliver=[&](bool finished){
            auto n=jsize(probabilities.size());auto p=e->NewFloatArray(n),r=e->NewFloatArray(n),k=e->NewFloatArray(n);
            if(!p||!r||!k)throw std::runtime_error("voice_allocation");
            if(n){e->SetFloatArrayRegion(p,0,n,probabilities.data());e->SetFloatArrayRegion(r,0,n,levels.data());e->SetFloatArrayRegion(k,0,n,peaks.data());}
            keep=e->CallBooleanMethod(listener,callback,batchStart,p,r,k,finished?JNI_TRUE:JNI_FALSE)==JNI_TRUE;
            e->DeleteLocalRef(p);e->DeleteLocalRef(r);e->DeleteLocalRef(k);
            if(e->ExceptionCheck())throw std::runtime_error("voice_callback");
            probabilities.clear();levels.clear();peaks.clear();batchStart=start+cursor/16000.;
        };
        auto sample=[&](float value){
            block[used++]=value;++cursor;
            if(used==512){
                if(VoiceJob::interrupt(job.get()))throw std::runtime_error("voice_cancelled");
                double power=0;float peak=0;for(float x:block){power+=double(x)*x;peak=std::max(peak,std::abs(x));}
                probabilities.push_back(vad.run(block.data()));levels.push_back(float(std::sqrt(power/512)));peaks.push_back(peak);used=0;
                if(probabilities.size()==32)deliver(false);
            }
        };
        double next=std::numeric_limits<double>::quiet_NaN();
        auto receive=[&](){
            while(keep&&cursor<wanted){
                int result=avcodec_receive_frame(a.codec,a.frame);if(result==AVERROR(EAGAIN)||result==AVERROR_EOF)break;
                if(result<0)throw std::runtime_error("voice_decode_failed");
                auto* f=a.frame;double at=f->best_effort_timestamp==AV_NOPTS_VALUE?next:f->best_effort_timestamp*av_q2d(stream->time_base)-origin;
                if(!std::isfinite(at)||f->sample_rate<=0)throw std::runtime_error("voice_timestamp");
                if(!a.swr){
                    AVChannelLayout mono=AV_CHANNEL_LAYOUT_MONO;
                    if(swr_alloc_set_opts2(&a.swr,&mono,AV_SAMPLE_FMT_FLT,16000,&f->ch_layout,AVSampleFormat(f->format),f->sample_rate,0,nullptr)<0||swr_init(a.swr)<0)throw std::runtime_error("voice_resample");
                }
                at-=swr_get_delay(a.swr,f->sample_rate)/double(f->sample_rate);
                int capacity=int(av_rescale_rnd(swr_get_delay(a.swr,f->sample_rate)+f->nb_samples,16000,f->sample_rate,AV_ROUND_UP));
                if(capacity<0||capacity>32000)throw std::runtime_error("voice_frame_limit");
                std::vector<float> pcm(capacity);auto* out=reinterpret_cast<uint8_t*>(pcm.data());
                int count=swr_convert(a.swr,&out,capacity,const_cast<const uint8_t**>(f->extended_data),f->nb_samples);
                if(count<0)throw std::runtime_error("voice_resample");
                int64_t offset=int64_t(std::llround((at-start)*16000));
                while(keep&&cursor<std::min(offset,wanted))sample(0);
                for(int64_t i=std::max(int64_t(0),cursor-offset);keep&&i<count&&cursor<wanted;++i)sample(pcm[size_t(i)]);
                next=at+count/16000.;av_frame_unref(f);
            }
        };
        int packets=0;
        while(keep&&cursor<wanted&&packets++<2000000){
            if(VoiceJob::interrupt(job.get()))throw std::runtime_error("voice_cancelled");
            int result=av_read_frame(a.format,a.packet);
            if(result==AVERROR_EOF){avcodec_send_packet(a.codec,nullptr);receive();eof=true;break;}
            if(result<0)throw std::runtime_error("voice_read_failed");
            if(anchor!=index&&a.packet->stream_index==anchor)a.format->streams[anchor]->discard=AVDISCARD_ALL;
            if(a.packet->stream_index==index){int r=avcodec_send_packet(a.codec,a.packet);if(r==AVERROR(EAGAIN)){receive();r=avcodec_send_packet(a.codec,a.packet);}if(r<0)throw std::runtime_error("voice_decode_failed");receive();}
            av_packet_unref(a.packet);
        }
        if(packets>=2000000)throw std::runtime_error("voice_scan_limit");
        // Partial last frame is discarded, never pad a candidate beyond actual audio.
        if(keep)deliver(eof||cursor>=wanted);
    }catch(const std::exception&){narration_error(e,"voice_scan_failed");}
}
