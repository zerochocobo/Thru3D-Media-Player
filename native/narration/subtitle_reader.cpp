// Uses the exact FFmpeg headers/binaries already pinned for MPV. No video decode.
#include "jni_text.h"
#include "json.hpp"
extern "C" {
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavcodec/codec_desc.h>
}
#include <algorithm>
#include <atomic>
#include <chrono>
#include <map>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <vector>

namespace {
using J=nlohmann::json;
using Clock=std::chrono::steady_clock;
struct Reader {
    std::string path, ca;
    int stream;
    AVFormatContext* format=nullptr;
    AVCodecContext* codec=nullptr;
    std::atomic<bool> cancelled{false};
    Clock::time_point deadline;
    std::mutex mutex;
    J cues=J::array();
    double read_until=-1;
    bool eof=false, initialized=false;
    Reader(std::string p,int s,std::string c):path(std::move(p)),ca(std::move(c)),stream(s) {}
    ~Reader() {avcodec_free_context(&codec);avformat_close_input(&format);}
    static int interrupt(void* p) {auto* r=static_cast<Reader*>(p);return r->cancelled.load()||Clock::now()>r->deadline;}
    void open(double position) {
        format=avformat_alloc_context();if(!format)throw std::runtime_error("Allocation failed");
        format->interrupt_callback={interrupt,this};
        AVDictionary* options=nullptr;
        av_dict_set(&options,"rw_timeout","8000000",0);av_dict_set(&options,"tls_verify","1",0);
        av_dict_set(&options,"protocol_whitelist","file,http,https,tcp,tls,crypto",0);
        av_dict_set(&options,"user_agent","Thru3D subtitle reader",0);
        if(!ca.empty())av_dict_set(&options,"ca_file",ca.c_str(),0);
        std::string location=path.rfind("fd://",0)==0?"/proc/self/fd/"+path.substr(5):path;
        int result=avformat_open_input(&format,location.c_str(),nullptr,&options);av_dict_free(&options);
        if(result<0)throw std::runtime_error("Unable to open subtitle source");
        // Header metadata is sufficient for the selected text stream. Do not call
        // find_stream_info(): probing can decode video/audio behind our back.
        if(stream<0||unsigned(stream)>=format->nb_streams)throw std::runtime_error("Subtitle stream unavailable");
        auto* parameters=format->streams[stream]->codecpar;
        auto* description=avcodec_descriptor_get(parameters->codec_id);
        if(parameters->codec_type!=AVMEDIA_TYPE_SUBTITLE||!description||!(description->props&AV_CODEC_PROP_TEXT_SUB))
            throw std::runtime_error("Text subtitles required");
        auto* decoder=avcodec_find_decoder(parameters->codec_id);
        if(!decoder)throw std::runtime_error("Subtitle decoder unavailable");
        codec=avcodec_alloc_context3(decoder);
        if(!codec||avcodec_parameters_to_context(codec,parameters)<0||avcodec_open2(codec,decoder,nullptr)<0)throw std::runtime_error("Subtitle decoder unavailable");
        for(unsigned i=0;i<format->nb_streams;++i)if(i!=unsigned(stream))format->streams[i]->discard=AVDISCARD_ALL;
        if(position>5) {
            auto timestamp=int64_t((position-5)/av_q2d(format->streams[stream]->time_base));
            if(av_seek_frame(format,stream,timestamp,AVSEEK_FLAG_BACKWARD)>=0)avcodec_flush_buffers(codec);
        }
        initialized=true;
    }
    J window(double start,double end) {
        std::lock_guard<std::mutex> lock(mutex);
        deadline=Clock::now()+std::chrono::seconds(8);
        if(cancelled.load())return J::array();
        if(!initialized)open(start);
        const double base=av_q2d(format->streams[stream]->time_base);
        std::unique_ptr<AVPacket,void(*)(AVPacket*)> packet(av_packet_alloc(),[](AVPacket* p){av_packet_free(&p);});
        if(!packet)throw std::runtime_error("Allocation failed");
        for(int count=0;!eof&&read_until<end&&count<150000&&!interrupt(this);++count) {
            int status=av_read_frame(format,packet.get());
            if(status==AVERROR_EOF) {eof=true;break;}
            if(status<0)throw std::runtime_error("Unable to read subtitles");
            if(packet->stream_index==stream) {
                AVSubtitle subtitle{};int got=0;
                int decoded=avcodec_decode_subtitle2(codec,&subtitle,&got,packet.get());
                double pts=packet->pts==AV_NOPTS_VALUE?packet->dts*base:packet->pts*base;
                if(packet->pts==AV_NOPTS_VALUE&&packet->dts==AV_NOPTS_VALUE)pts=-1;
                if(decoded>=0&&got&&pts>=0) {
                    double begin=pts+subtitle.start_display_time/1000.0;
                    double duration=packet->duration>0?packet->duration*base:0;
                    if(subtitle.end_display_time>subtitle.start_display_time&&subtitle.end_display_time<120000)
                        duration=(subtitle.end_display_time-subtitle.start_display_time)/1000.0;
                    duration=std::clamp(duration,0.1,120.0);
                    std::string text;
                    for(unsigned i=0;i<subtitle.num_rects;++i) {
                        auto* rectangle=subtitle.rects[i];std::string line;
                        if(rectangle->text)line=rectangle->text;
                        else if(rectangle->ass) {line=rectangle->ass;size_t offset=0;int fields=0;
                            for(;fields<8;++fields) {auto comma=line.find(',',offset);if(comma==std::string::npos)break;offset=comma+1;}
                            if(fields==8)line.erase(0,offset);
                        }
                        if(!line.empty()) {if(!text.empty())text+='\n';text+=line.substr(0,8192);}
                    }
                    if(!text.empty()&&begin+duration>=start-1)cues.push_back({{"start",begin},{"end",begin+duration},{"text",text.substr(0,8192)}});
                }
                avsubtitle_free(&subtitle);
                if(pts>=0)read_until=std::max(read_until,pts);
            }
            av_packet_unref(packet.get());
            if(cues.size()>4096)throw std::runtime_error("Subtitle window too large");
        }
        if(interrupt(this)&&!cancelled.load())throw std::runtime_error("Subtitle read timed out");
        J kept=J::array(),result=J::array();
        for(auto& cue:cues) if(cue["end"].get<double>()>=start-1) {
            if(cue["start"].get<double>()<end)result.push_back(cue);
            kept.push_back(std::move(cue));
        }
        cues=std::move(kept);return result;
    }
};
std::mutex readers_mutex;
std::map<int64_t,std::shared_ptr<Reader>> readers;
int64_t next_reader=0;
}
extern "C" JNIEXPORT jlong JNICALL Java_org_vrpassthroughplayer_plugin_NarrationNative_openReader(JNIEnv* e,jclass,jstring path,jint stream,jstring ca) {
    try {
        auto reader=std::make_shared<Reader>(narration_utf8(e,path),stream,narration_utf8(e,ca));
        std::lock_guard<std::mutex> lock(readers_mutex);auto id=++next_reader;readers[id]=reader;return id;
    } catch(const std::exception&) {narration_error(e,"Unable to prepare subtitle reader");return 0;}
}
extern "C" JNIEXPORT void JNICALL Java_org_vrpassthroughplayer_plugin_NarrationNative_closeReader(JNIEnv*,jclass,jlong id) {
    std::lock_guard<std::mutex> lock(readers_mutex);auto it=readers.find(id);if(it!=readers.end()) {it->second->cancelled.store(true);readers.erase(it);}
}
extern "C" JNIEXPORT jstring JNICALL Java_org_vrpassthroughplayer_plugin_NarrationNative_readWindow(JNIEnv* e,jclass,jlong id,jdouble start,jdouble end) {
    try {
        std::shared_ptr<Reader> reader;
        {std::lock_guard<std::mutex> lock(readers_mutex);auto it=readers.find(id);if(it==readers.end())return e->NewStringUTF("[]");reader=it->second;}
        if(!std::isfinite(start)||!std::isfinite(end)||start<0||end<=start||end-start>60)throw std::runtime_error("Invalid subtitle window");
        return e->NewStringUTF(reader->window(start,end).dump(-1,' ',true).c_str());
    } catch(const std::exception&) {narration_error(e,"Unable to prepare subtitle timeline");return nullptr;}
}
