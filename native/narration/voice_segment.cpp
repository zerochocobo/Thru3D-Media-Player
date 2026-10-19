#include "jni_text.h"
#include <algorithm>
#include "voice_io.h"
extern "C" {
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libswresample/swresample.h>
}
#include <atomic>
#include <chrono>
#include <map>
#include <memory>
#include <mutex>
namespace {
struct Job {
    std::atomic<bool> cancelled{false};
    std::chrono::steady_clock::time_point deadline=std::chrono::steady_clock::now()+std::chrono::seconds(30);
    static int interrupt(void* p){auto& j=*static_cast<Job*>(p);return j.cancelled.load()||std::chrono::steady_clock::now()>j.deadline;}
};
std::mutex jobs_mutex;std::map<int64_t,std::shared_ptr<Job>> jobs;int64_t next_job=0;
struct Audio {
    AVFormatContext* format=nullptr;AVCodecContext* codec=nullptr;SwrContext* swr=nullptr;SwrContext* center_swr=nullptr;
    AVPacket* packet=av_packet_alloc();AVFrame* frame=av_frame_alloc();
    ~Audio(){av_frame_free(&frame);av_packet_free(&packet);swr_free(&swr);swr_free(&center_swr);avcodec_free_context(&codec);avformat_close_input(&format);}
};
}
extern "C" JNIEXPORT jlong JNICALL Java_org_vrpassthroughplayer_plugin_VoiceCloneNative_createJob(JNIEnv* e,jclass){
    std::lock_guard<std::mutex> lock(jobs_mutex);if(jobs.size()>=8){narration_error(e,"Too many voice tasks");return 0;}
    auto id=++next_job;jobs[id]=std::make_shared<Job>();return id;
}
extern "C" JNIEXPORT void JNICALL Java_org_vrpassthroughplayer_plugin_VoiceCloneNative_cancelJob(JNIEnv*,jclass,jlong id){
    std::lock_guard<std::mutex> lock(jobs_mutex);auto it=jobs.find(id);if(it!=jobs.end()){it->second->cancelled=true;jobs.erase(it);}
}
extern "C" JNIEXPORT void JNICALL Java_org_vrpassthroughplayer_plugin_VoiceCloneNative_extract(JNIEnv* e,jclass,jlong id,jstring input,jint index,jstring ca,jdouble start,jdouble end,jstring output,jboolean disc){
    try {
        std::shared_ptr<Job> job;{std::lock_guard<std::mutex> lock(jobs_mutex);job=jobs.at(id);}
        if(!std::isfinite(start)||!std::isfinite(end)||start<0||end-start<3-1e-6||end-start>10+1e-6||index<0)throw std::runtime_error("Invalid segment");
        Audio a;if(!a.packet||!a.frame)throw std::runtime_error("Allocation failed");
        a.format=avformat_alloc_context();if(!a.format)throw std::runtime_error("Allocation failed");a.format->interrupt_callback={Job::interrupt,job.get()};
        AVDictionary* options=nullptr;av_dict_set(&options,"rw_timeout","8000000",0);av_dict_set(&options,"tls_verify","1",0);
        av_dict_set(&options,"protocol_whitelist","file,http,https,tcp,tls,crypto",0);av_dict_set(&options,"user_agent","Thru3D voice reader",0);
        auto trust=narration_utf8(e,ca);if(!trust.empty())av_dict_set(&options,"ca_file",trust.c_str(),0);
        auto path=narration_utf8(e,input);if(path.rfind("fd://",0)==0)path="/proc/self/fd/"+path.substr(5);
        const AVInputFormat* demuxer=disc==JNI_TRUE?av_find_input_format("bd_mvc"):nullptr;
        if(disc==JNI_TRUE&&!demuxer){av_dict_free(&options);throw std::runtime_error("Disc demuxer unavailable");}
        int status=avformat_open_input(&a.format,path.c_str(),demuxer,&options);av_dict_free(&options);
        if(status<0||unsigned(index)>=a.format->nb_streams)throw std::runtime_error("Audio source unavailable");
        auto* stream=a.format->streams[index];auto* parameters=stream->codecpar;
        if(parameters->codec_type!=AVMEDIA_TYPE_AUDIO)throw std::runtime_error("Audio track unavailable");
        for(unsigned i=0;i<a.format->nb_streams;++i)if(int(i)!=index)a.format->streams[i]->discard=AVDISCARD_ALL;
        auto* decoder=avcodec_find_decoder(parameters->codec_id);if(!decoder)throw std::runtime_error("Audio decoder unavailable");
        a.codec=avcodec_alloc_context3(decoder);if(!a.codec||avcodec_parameters_to_context(a.codec,parameters)<0||avcodec_open2(a.codec,decoder,nullptr)<0)throw std::runtime_error("Audio decoder failed");
        double origin=a.format->start_time==AV_NOPTS_VALUE?0:a.format->start_time/double(AV_TIME_BASE);
        // Matroska usually indexes video only. All non-audio streams are
        // discarded above, so FFmpeg's default stream now becomes the audio
        // stream and may fall back to scanning a remote movie from its start.
        // Seek the indexed video explicitly; still never open a video decoder.
        int anchor=index;
        for(unsigned i=0;i<a.format->nb_streams;++i)if(a.format->streams[i]->codecpar->codec_type==AVMEDIA_TYPE_VIDEO&&
            !(a.format->streams[i]->disposition&AV_DISPOSITION_ATTACHED_PIC)){anchor=int(i);break;}
        // The demuxer must see the anchor keyframe to finish seeking. Discarding
        // it entirely can leave Matroska skipping every subsequent audio packet.
        if(anchor!=index)a.format->streams[anchor]->discard=AVDISCARD_NONKEY;
        const auto time_base=av_q2d(a.format->streams[anchor]->time_base);
        if(!std::isfinite(time_base)||time_base<=0)throw std::runtime_error("Audio timestamp unavailable");
        if(start>0&&av_seek_frame(a.format,anchor,int64_t((origin+std::max(0.,start-1))/time_base),AVSEEK_FLAG_BACKWARD)<0)throw std::runtime_error("Audio seek failed");
        avcodec_flush_buffers(a.codec);
        const int wanted=int(std::llround((end-start)*48000));std::vector<float> pcm(wanted*2,0),center;int first=wanted,last=0;double next_time=std::numeric_limits<double>::quiet_NaN();
        auto receive=[&](){
            for(;;){int r=avcodec_receive_frame(a.codec,a.frame);if(r==AVERROR(EAGAIN)||r==AVERROR_EOF)break;if(r<0)throw std::runtime_error("Audio decode failed");
                if(Job::interrupt(job.get()))throw std::runtime_error("Cancelled");
                auto* f=a.frame;double at=f->best_effort_timestamp==AV_NOPTS_VALUE?next_time:f->best_effort_timestamp*av_q2d(stream->time_base)-origin;
                if(!std::isfinite(at)||f->sample_rate<=0||f->nb_samples<=0)throw std::runtime_error("Audio timestamp unavailable");
                if(!a.swr){AVChannelLayout stereo=AV_CHANNEL_LAYOUT_STEREO;
                    if(swr_alloc_set_opts2(&a.swr,&stereo,AV_SAMPLE_FMT_FLT,48000,&f->ch_layout,AVSampleFormat(f->format),f->sample_rate,0,nullptr)<0)throw std::runtime_error("Audio conversion failed");
                    // Match the tokenizer's mono duplication, without the default -3dB pan law.
                    if(f->ch_layout.nb_channels==1){const double matrix[]{1.,1.};if(swr_set_matrix(a.swr,matrix,1)<0)throw std::runtime_error("Audio conversion failed");}
                    if(swr_init(a.swr)<0)throw std::runtime_error("Audio conversion failed");
                    const int ci=av_channel_layout_index_from_channel(&f->ch_layout,AV_CHAN_FRONT_CENTER);
                    if(f->ch_layout.nb_channels>=3&&ci>=0){
                        if(swr_alloc_set_opts2(&a.center_swr,&stereo,AV_SAMPLE_FMT_FLT,48000,&f->ch_layout,AVSampleFormat(f->format),f->sample_rate,0,nullptr)<0)throw std::runtime_error("Audio conversion failed");
                        std::vector<double> matrix(f->ch_layout.nb_channels*2,0.);matrix[ci]=matrix[f->ch_layout.nb_channels+ci]=1.;
                        if(swr_set_matrix(a.center_swr,matrix.data(),f->ch_layout.nb_channels)<0||swr_init(a.center_swr)<0)throw std::runtime_error("Audio conversion failed");
                        center.resize(wanted*2,0);
                    }}
                double delay=swr_get_delay(a.swr,f->sample_rate)/double(f->sample_rate);at-=delay;
                int capacity=int(av_rescale_rnd(swr_get_delay(a.swr,f->sample_rate)+f->nb_samples,48000,f->sample_rate,AV_ROUND_UP));
                if(capacity<0||capacity>48000*2)throw std::runtime_error("Audio frame limit");std::vector<float> converted(capacity*2);uint8_t* target=reinterpret_cast<uint8_t*>(converted.data());
                int count=swr_convert(a.swr,&target,capacity,const_cast<const uint8_t**>(f->extended_data),f->nb_samples);if(count<0)throw std::runtime_error("Audio conversion failed");
                int offset=int(std::llround((at-start)*48000));int lo=std::max(0,offset),hi=std::min(wanted,offset+count);
                if(hi>lo){std::copy_n(converted.begin()+(lo-offset)*2,(hi-lo)*2,pcm.begin()+lo*2);first=std::min(first,lo);last=std::max(last,hi);}
                if(a.center_swr){
                    std::vector<float> dialogue(capacity*2);uint8_t* center_target=reinterpret_cast<uint8_t*>(dialogue.data());
                    int center_count=swr_convert(a.center_swr,&center_target,capacity,const_cast<const uint8_t**>(f->extended_data),f->nb_samples);
                    if(center_count!=count)throw std::runtime_error("Audio conversion failed");
                    if(hi>lo)std::copy_n(dialogue.begin()+(lo-offset)*2,(hi-lo)*2,center.begin()+lo*2);
                }
                next_time=at+count/48000.;av_frame_unref(f);
            }
        };
        int packets=0;for(;last<wanted&&packets<150000&&!Job::interrupt(job.get());++packets){
            status=av_read_frame(a.format,a.packet);if(status==AVERROR_EOF){avcodec_send_packet(a.codec,nullptr);receive();break;}if(status<0)throw std::runtime_error("Audio read failed");
            if(a.packet->stream_index==index){int r=avcodec_send_packet(a.codec,a.packet);if(r==AVERROR(EAGAIN)){receive();r=avcodec_send_packet(a.codec,a.packet);}if(r<0)throw std::runtime_error("Audio decode failed");receive();}
            av_packet_unref(a.packet);
        }
        if(Job::interrupt(job.get())||packets>=150000||first>480||last<wanted-480)throw std::runtime_error("Incomplete audio segment");
        const auto destination=narration_utf8(e,output);voiceio::wav(destination,pcm);
        // Preserve the mix as a fallback. Reference preparation (including audition)
        // uses the center only when it carries signal; silent/missing centers fall back.
        if(!center.empty()){
            double ce=0,me=0;for(size_t i=0;i<pcm.size();++i){ce+=double(center[i])*center[i];me+=double(pcm[i])*pcm[i];}
            if(ce/center.size()>1e-6&&ce>=me*.01)voiceio::wav(destination+".dialogue.wav",center);
        }
    }catch(const std::exception& failure){
        // Every message above is a fixed stage; do not expose a source URL/path.
        const std::string message=std::string("voice_extract:")+failure.what();
        narration_error(e,message.c_str());
    }
}
