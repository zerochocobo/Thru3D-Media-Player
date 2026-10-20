#pragma once
#include "../original_clip_core.h"
#include <array>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <map>
#include <cmath>
#include <mutex>
#include <thread>
#include <unordered_map>
#include <unistd.h>

namespace quest::live {
constexpr int sample_rate = 48000, audio_frames = 1024;
constexpr size_t video_budget = 64u * 1024u * 1024u;
inline int64_t monotonic_ns() {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
}
using Packet = std::shared_ptr<AVPacket>;
inline Packet retain(const AVPacket* packet) {
    auto* copy = av_packet_clone(packet);
    if (!copy) throw std::bad_alloc();
    return Packet(copy, [](AVPacket* p) { av_packet_free(&p); });
}
using Codec = std::shared_ptr<AVCodecParameters>;
inline Codec retain(const AVCodecParameters* codec) {
    auto* copy = avcodec_parameters_alloc();
    if (!copy) throw std::bad_alloc();
    Codec result(copy, [](AVCodecParameters* p) { avcodec_parameters_free(&p); });
    capture::check(avcodec_parameters_copy(copy, codec)); return result;
}
// Bounded MPSC queue. Producers never acquire a lock or wait for the disk worker.
template<class T, size_t N> class Queue {
    struct Cell { std::atomic<size_t> sequence{}; T value{}; };
    std::unique_ptr<Cell[]> cells{new Cell[N]};
    std::atomic<size_t> head{0}; size_t tail = 0;
public:
    Queue() { for (size_t i=0;i<N;++i) cells[i].sequence.store(i); }
    template<class Fill> bool offer(Fill fill) {
        size_t position=head.load(std::memory_order_relaxed);
        for (;;) {
            auto& cell=cells[position%N];
            const auto difference=static_cast<intptr_t>(cell.sequence.load(std::memory_order_acquire))-static_cast<intptr_t>(position);
            if (difference<0) return false;
            if (difference==0 && head.compare_exchange_weak(position,position+1,std::memory_order_relaxed)) {
                fill(cell.value); cell.sequence.store(position+1,std::memory_order_release); return true;
            }
            if (difference>0) position=head.load(std::memory_order_relaxed);
        }
    }
    bool take(T& result) {
        auto& cell=cells[tail%N];
        if (cell.sequence.load(std::memory_order_acquire)!=tail+1) return false;
        result=std::move(cell.value); cell.value=T{};
        cell.sequence.store(tail+N,std::memory_order_release); ++tail; return true;
    }
};
struct Audio {
    uint64_t owner=0; int frames=0, rate=0, channels=0, format=0; int64_t ns=0;
    float gain=1; std::array<unsigned char,audio_frames*2*sizeof(float)> bytes{};
    int64_t end_ns() const { return ns+static_cast<int64_t>(frames)*1000000000/rate; }
};
struct FileClose {void operator()(FILE* file)const{if(file)std::fclose(file);}};
struct Clock { int64_t ns=0, us=0; bool playing=false; };

// One instance per AAudio stream; only that stream's serialized callback mutates
// it. Close/reset call only after the device callback has stopped or joined.
class PresentedAudio {
    struct Part {Audio chunk;int64_t frame=0;int emitted=0;};
    std::array<Part,64> parts{};
    size_t first=0,count=0;
    bool anchored=false;
    int anchor_rate=0;
    int64_t anchor_frame=0,anchor_ns=0;
public:
    void discontinuity(){anchored=false;}
    void reset(){first=0;count=0;discontinuity();}
    bool submit(const Audio& chunk,int64_t frame) {
        if(count==parts.size())return false;
        auto& part=parts[(first+count++)%parts.size()];part.chunk=chunk;part.frame=frame;part.emitted=0;return true;
    }
    template<class Sink> void present(int64_t frame,int64_t ns,Sink sink) {
        while(count) {
            auto& part=parts[first];
            const int available=static_cast<int>(std::clamp<int64_t>(frame-part.frame,0,part.chunk.frames));
            if(available>part.emitted) {
                Audio output=part.chunk;output.frames=available-part.emitted;
                if(!anchored||anchor_rate!=output.rate) {
                    anchor_frame=frame;anchor_ns=ns;anchor_rate=output.rate;anchored=true;
                }
                // Device timestamp observations jitter. Adjacent played sample
                // ranges stay on one clock until a real pause/reset/underrun.
                output.ns=anchor_ns+(part.frame+part.emitted-anchor_frame)*1000000000/output.rate;
                const int stride=part.chunk.channels*(part.chunk.format==2?2:4);
                std::memmove(output.bytes.data(),output.bytes.data()+part.emitted*stride,output.frames*stride);
                sink(output);part.emitted=available;
            }
            if(part.emitted<part.chunk.frames)break;
            first=(first+1)%parts.size();--count;
        }
    }
};

class Wave {
    FILE* file=nullptr;
    int64_t cursor=0;
    std::map<int64_t,std::array<float,960>> blocks; // 10 ms, stereo
    std::unordered_map<uint64_t,int64_t> heard;
    static void put(FILE* f,uint64_t value,int count) { for(int i=0;i<count;++i) { if(std::fputc(value&255,f)==EOF) throw std::runtime_error("Not enough storage"); value>>=8; } }
    static void bytes(FILE* f,const void* data,size_t size) { if(std::fwrite(data,1,size,f)!=size) throw std::runtime_error("Not enough storage"); }
public:
    explicit Wave(const std::string& path) {
        file=std::fopen(path.c_str(),"wb+"); if(!file) throw std::runtime_error("Capture save failed");
        // RF64 avoids the 4 GiB WAV limit without a second encoding pass.
        bytes(file,"RF64",4);put(file,0xffffffff,4);bytes(file,"WAVEds64",8);put(file,28,4);
        put(file,0,8);put(file,0,8);put(file,0,8);put(file,0,4);
        bytes(file,"fmt ",4);put(file,16,4);put(file,3,2);put(file,2,2);put(file,sample_rate,4);
        put(file,sample_rate*8,4);put(file,8,2);put(file,32,2);bytes(file,"data",4);put(file,0xffffffff,4);
    }
    ~Wave(){if(file)std::fclose(file);}
    void add(const Audio& audio,const Clock& clock,int64_t base_us,int64_t begin_ns,int64_t end_ns) {
        if(!clock.playing) return;
        auto& previous=heard[audio.owner];
        const int64_t first=std::max({audio.ns,previous,begin_ns});
        const int64_t last=std::min(audio.end_ns(),end_ns);
        previous=std::max(previous,last);
        if(last<=first) return;
        auto sample=[&](int frame,int channel) {
            const int index=frame*audio.channels+std::min(channel,audio.channels-1);
            if(audio.format==1) { float value;std::memcpy(&value,audio.bytes.data()+index*4,4);return std::isfinite(value)?value*audio.gain:0.f; }
            if(audio.format==3) {int32_t value;std::memcpy(&value,audio.bytes.data()+index*4,4);return static_cast<float>(value/2147483648.0)*audio.gain;}
            int16_t value;std::memcpy(&value,audio.bytes.data()+index*2,2);return value/32768.f*audio.gain;
        };
        const int64_t position=av_rescale_rnd(clock.us-base_us,sample_rate,1000000,AV_ROUND_NEAR_INF)+
            av_rescale_rnd(first-clock.ns,sample_rate,1000000000,AV_ROUND_NEAR_INF);
        const int64_t end=av_rescale_rnd(clock.us-base_us,sample_rate,1000000,AV_ROUND_NEAR_INF)+
            av_rescale_rnd(last-clock.ns,sample_rate,1000000000,AV_ROUND_NEAR_INF);
        const int count=static_cast<int>(end-position);
        for(int i=0;i<count;++i) {
            const int64_t output=position+i;
            if(output<cursor||output<0)continue;
            const double source=(first-audio.ns)/1e9*audio.rate+static_cast<double>(i)*audio.rate/sample_rate;
            const int a=std::min(static_cast<int>(source),audio.frames-1),b=std::min(a+1,audio.frames-1);
            const float mix=static_cast<float>(source-a);
            auto& block=blocks[output/480];
            if(blocks.size()>500)throw std::runtime_error("Capture clock stalled");
            for(int channel=0;channel<2;++channel)block[(output%480)*2+channel]+=sample(a,channel)*(1-mix)+sample(b,channel)*mix;
        }
    }
    void flush(int64_t frames) {
        while(cursor<frames) {
            const int count=static_cast<int>(std::min<int64_t>(480-cursor%480,frames-cursor));
            auto found=blocks.find(cursor/480);
            std::array<float,960> data{};
            if(found!=blocks.end())for(int i=0;i<count*2;++i)data[i]=std::clamp(found->second[(cursor%480)*2+i],-1.f,1.f);
            bytes(file,data.data(),count*2*sizeof(float)); cursor+=count;
            if(cursor%480==0&&found!=blocks.end())blocks.erase(found);
        }
    }
    void finish(int64_t frames) {
        flush(frames);
        // Buffered future output past the stop boundary must never appear in the file.
        if(std::fflush(file)||ftruncate(fileno(file),80+frames*8))throw std::runtime_error("Capture save failed");
        std::fseek(file,20,SEEK_SET);put(file,72+frames*8,8);put(file,frames*8,8);put(file,frames,8);
        if(std::fflush(file))throw std::runtime_error("Capture save failed");
    }
};

class Session {
    struct Stamp {int64_t pts,dts,duration;int32_t flags,size;};
    Codec codec;
    Queue<Packet,1024> packets;
    Queue<Audio,128> audio;
    std::atomic<size_t> queued_bytes{0};
    std::atomic<bool> finishing{false}, finished{false};
    std::atomic<bool> cancelled{false};
    std::atomic<bool> playback_busy{true};
    std::atomic<int64_t> stop_ns{INT64_MAX}, end_us{INT64_MAX};
    std::atomic<int64_t> latest_us{0};
    std::atomic<int64_t> source_us{0}, clock_deviation_us{0};
    std::atomic<int> failure{0};
    std::atomic<size_t> peak_bytes{0}, video_packets{0}, audio_samples{0}, lost_blocks{0};
    std::atomic<int64_t> callback_max_ns{0}, io_max_ns{0};
    template<class T> static void maximum(std::atomic<T>& target,T value){auto before=target.load();while(before<value&&!target.compare_exchange_weak(before,value)) {}}
    std::mutex clock_mutex, report_mutex;
    std::vector<Clock> clocks;
    std::thread worker;
    std::string error;
    void run() {
        try {
            capture::Output video;
            capture::check(avformat_alloc_output_context2(&video.ctx,nullptr,"matroska",nullptr));
            if(!video.ctx)throw std::runtime_error("Lossless container unavailable");
            auto* stream=avformat_new_stream(video.ctx,nullptr);if(!stream)throw std::bad_alloc();
            capture::check(avcodec_parameters_copy(stream->codecpar,codec.get()));stream->codecpar->codec_tag=0;
            stream->avg_frame_rate=codec->framerate;
            stream->time_base={1,1000000};video.ctx->avoid_negative_ts=AVFMT_AVOID_NEG_TS_DISABLED;
            capture::check(avio_open(&video.ctx->pb,video_path.c_str(),AVIO_FLAG_WRITE));
            capture::check(avformat_write_header(video.ctx,nullptr));
            std::unique_ptr<FILE,FileClose> index(std::fopen(index_path.c_str(),"wb"));
            if(!index)throw std::runtime_error("Capture save failed");
            Wave wave(audio_path);
            for(;;) {
                if(cancelled.load())throw std::runtime_error("Clip export cancelled");
                if(failure.load())throw std::runtime_error(failure.load()==2?"Capture audio format unavailable":failure.load()==4?"Capture audio clock unavailable":"Capture writer could not keep up");
                bool worked=false; Packet packet;
                for(int i=0;i<32&&packets.take(packet);++i) {
                    worked=true;queued_bytes.fetch_sub(packet->size);
                    const Stamp stamp{packet->pts,packet->dts,packet->duration,packet->flags,packet->size};
                    if(std::fwrite(&stamp,sizeof(stamp),1,index.get())!=1)throw std::runtime_error("Not enough storage");
                    packet->pts-=base_us;if(packet->dts!=AV_NOPTS_VALUE)packet->dts-=base_us;
                    av_packet_rescale_ts(packet.get(),AVRational{1,1000000},stream->time_base);
                    packet->stream_index=0;packet->pos=-1;
                    const auto started=monotonic_ns();
                    capture::check(av_interleaved_write_frame(video.ctx,packet.get()));packet.reset();
                    maximum(io_max_ns,monotonic_ns()-started);
                }
                Audio chunk;
                for(int i=0;i<128&&audio.take(chunk);++i) {
                    worked=true;std::vector<Clock> segments;
                    { std::lock_guard<std::mutex> lock(clock_mutex);
                      auto next=std::upper_bound(clocks.begin(),clocks.end(),chunk.ns,[](int64_t ns,const Clock& c){return ns<c.ns;});
                      if(next!=clocks.begin())--next;
                      do {segments.push_back(*next++);}while(next!=clocks.end()&&next->ns<chunk.end_ns()); }
                    for(size_t segment=0;segment<segments.size();++segment) {
                        const auto last=segment+1<segments.size()?segments[segment+1].ns:INT64_MAX;
                        wave.add(chunk,segments[segment],base_us,std::max(begin_ns,segments[segment].ns),std::min(stop_ns.load(),last));
                    }
                }
                if(finishing.load()&&!worked)break;
                // One second of local mixing headroom covers queued AAudio and heard-PCM reports.
                const auto safe_ns=monotonic_ns()-1000000000;
                Clock safe_clock;
                {std::lock_guard<std::mutex> lock(clock_mutex);
                 auto next=std::upper_bound(clocks.begin(),clocks.end(),safe_ns,[](int64_t ns,const Clock& c){return ns<c.ns;});
                 safe_clock=next==clocks.begin()?clocks.front():*std::prev(next);}
                const auto safe_us=std::min({end_us.load(),latest_us.load(),safe_clock.us+(safe_clock.playing?(safe_ns-safe_clock.ns)/1000:0)});
                if(safe_us>base_us){const auto started=monotonic_ns();wave.flush((safe_us-base_us)*sample_rate/1000000);maximum(io_max_ns,monotonic_ns()-started);}
                if(!worked)std::this_thread::sleep_for(std::chrono::milliseconds(2));
            }
            capture::check(av_write_trailer(video.ctx));avio_flush(video.ctx->pb);capture::check(video.ctx->pb->error);
            if(std::fflush(index.get()))throw std::runtime_error("Capture save failed");
            wave.finish(std::max<int64_t>(0,(begin_us+audio_duration()-base_us)*sample_rate/1000000));
        } catch(const std::exception& problem) {std::lock_guard<std::mutex> lock(report_mutex);error=problem.what();}
        finished.store(true);
    }
public:
    const int64_t base_us, begin_us, begin_ns;
    const std::string video_path, audio_path, index_path;
    Session(Codec params,int64_t first,int64_t begin,int64_t ns,bool playing,const std::string& path)
        :codec(std::move(params)),base_us(first),begin_us(begin),begin_ns(ns),video_path(path+".mkv"),audio_path(path+".wav"),index_path(path+".idx") {
        clocks.push_back({ns,begin,playing});
        latest_us.store(begin);
        source_us.store(begin);
    }
    ~Session(){if(worker.joinable()){if(!finishing.load())stop(begin_us);worker.join();}}
    void launch(){worker=std::thread([this]{run();});}
    void fail(int code=1){failure.store(code);}
    bool push(const AVPacket* input) noexcept {
        const auto started=monotonic_ns();
        try {
            auto packet=retain(input);
            const auto size=packet->size;queued_bytes.fetch_add(size);
            maximum(peak_bytes,queued_bytes.load());
            if(queued_bytes.load()>video_budget||!packets.offer([&](Packet& value){value=std::move(packet);})) {
                queued_bytes.fetch_sub(size);++lost_blocks;fail();return false;
            }
            ++video_packets;maximum(callback_max_ns,monotonic_ns()-started);
            return true;
        } catch(...){fail();return false;}
    }
    void push(const Audio& chunk) noexcept {
        const auto started=monotonic_ns();
        if(chunk.channels<1||chunk.channels>2||chunk.rate<8000||chunk.rate>192000||chunk.format<1||chunk.format>3){fail(2);return;}
        if(!audio.offer([&](Audio& value){value=chunk;})){++lost_blocks;fail();}
        audio_samples.fetch_add(chunk.frames);maximum(callback_max_ns,monotonic_ns()-started);
    }
    void clock(int64_t ns,int64_t position,bool playing) {
        playback_busy.store(playing);
        if(end_us.load()!=INT64_MAX)return;
        source_us.store(position);
        std::lock_guard<std::mutex> lock(clock_mutex);
        const auto& previous=clocks.back();
        const auto expected=previous.us+(previous.playing?(ns-previous.ns)/1000:0);
        latest_us.store(expected);
        maximum(clock_deviation_us,std::abs(expected-position));
        // Preserve actual heard cadence. Frame-time jitter must not stretch, overlap
        // or erase words. Only excluded playback pauses change the audio time mapping.
        if(previous.playing!=playing)clocks.push_back({ns,expected,playing});
        if(clocks.size()>1024) {
            auto oldest=std::lower_bound(clocks.begin(),clocks.end(),ns-2000000000,[](const Clock& c,int64_t time){return c.ns<time;});
            if(oldest!=clocks.begin())clocks.erase(clocks.begin(),std::prev(oldest));
        }
        if(clocks.size()>8192)fail();
    }
    void limit(int64_t position,int64_t ns){end_us.store(position);stop_ns.store(ns);}
    void cancel(){cancelled.store(true);stop(begin_us);}
    void stop(int64_t position,int64_t ns=monotonic_ns()) {if(end_us.load()==INT64_MAX)limit(position,ns);finishing.store(true);}
    bool done()const{return finished.load();}
    int64_t end()const{return end_us.load();}
    int64_t position()const{return source_us.load();}
    int64_t audio_duration() {
        const auto ns=stop_ns.load()==INT64_MAX?monotonic_ns():stop_ns.load();
        std::lock_guard<std::mutex> lock(clock_mutex);
        auto next=std::upper_bound(clocks.begin(),clocks.end(),ns,[](int64_t time,const Clock& c){return time<c.ns;});
        const auto& clock=next==clocks.begin()?clocks.front():*std::prev(next);
        return std::max<int64_t>(0,clock.us+(clock.playing?(ns-clock.ns)/1000:0)-begin_us);
    }
    std::string export_file(const std::string& path,const std::string& mode) {
        try {
            if(!done()||audio_duration()<=0)throw std::runtime_error("Recording is empty");
            struct Local {
                AVFormatContext* ctx=nullptr;
                explicit Local(const std::string& name) {
                    AVDictionary* options=nullptr;av_dict_set(&options,"protocol_whitelist","file",0);
                    int result=avformat_open_input(&ctx,name.c_str(),nullptr,&options);av_dict_free(&options);capture::check(result);
                }
                ~Local(){if(ctx)avformat_close_input(&ctx);}
            } video(video_path), pcm(audio_path);
            // These files were produced above with complete known parameters.
            // No find_stream_info, decoder probing, network reader or audio synthesis.
            if(video.ctx->nb_streams!=1||pcm.ctx->nb_streams!=1)throw std::runtime_error("Capture save failed");
            capture::Output output;
            capture::check(avformat_alloc_output_context2(&output.ctx,nullptr,"matroska",nullptr));
            if(!output.ctx)throw std::runtime_error("Lossless container unavailable");
            auto* out_video=avformat_new_stream(output.ctx,nullptr);auto* out_audio=avformat_new_stream(output.ctx,nullptr);
            if(!out_video||!out_audio)throw std::bad_alloc();
            capture::check(avcodec_parameters_copy(out_video->codecpar,codec.get()));out_video->codecpar->codec_tag=0;out_video->time_base={1,1000000};
            out_video->avg_frame_rate=codec->framerate;
            capture::check(avcodec_parameters_copy(out_audio->codecpar,pcm.ctx->streams[0]->codecpar));out_audio->codecpar->codec_tag=0;
            out_audio->time_base=pcm.ctx->streams[0]->time_base;
            av_dict_set(&output.ctx->metadata,"thru3d_mode",mode.c_str(),0);
            av_dict_set(&out_audio->metadata,"title","Live audio",0);
            output.ctx->avoid_negative_ts=AVFMT_AVOID_NEG_TS_MAKE_NON_NEGATIVE;
            capture::check(avio_open(&output.ctx->pb,path.c_str(),AVIO_FLAG_WRITE));
            capture::check(avformat_write_header(output.ctx,nullptr));
            std::unique_ptr<FILE,FileClose> index(std::fopen(index_path.c_str(),"rb"));
            if(!index)throw std::runtime_error("Capture save failed");
            auto v=capture::packet(),a=capture::packet();bool have_v=false,have_a=false,video_end=false,audio_end=false;
            size_t count=0;
            constexpr double bytes_per_second=8.0*1024*1024,burst=256.0*1024;
            double tokens=burst;auto last_budget=monotonic_ns();
            while(true) {
                if(cancelled.load())throw std::runtime_error("Clip export cancelled");
                if(!have_v&&!video_end) {
                    int result=av_read_frame(video.ctx,v.get());
                    if(result==AVERROR_EOF)video_end=true;
                    else {
                        capture::check(result);Stamp stamp{};
                        if(std::fread(&stamp,sizeof(stamp),1,index.get())!=1)throw std::runtime_error("Capture save failed");
                        const auto decode=stamp.dts==AV_NOPTS_VALUE?stamp.pts:stamp.dts;
                        if(decode>=end())video_end=true;
                        else {v->pts=stamp.pts-base_us;v->dts=stamp.dts==AV_NOPTS_VALUE?AV_NOPTS_VALUE:stamp.dts-base_us;
                            v->duration=stamp.duration;v->flags=stamp.flags;have_v=true;}
                    }
                }
                if(!have_a&&!audio_end) {
                    int result=av_read_frame(pcm.ctx,a.get());
                    if(result==AVERROR_EOF)audio_end=true;else {capture::check(result);have_a=true;}
                }
                if(!have_v&&!have_a)break;
                const auto video_time=have_v?(v->dts==AV_NOPTS_VALUE?v->pts:v->dts):INT64_MAX;
                const auto audio_time=have_a?av_rescale_q(a->pts,pcm.ctx->streams[0]->time_base,AVRational{1,1000000}):INT64_MAX;
                const bool is_video=have_v&&video_time<=audio_time;
                auto* packet=is_video?v.get():a.get();
                // Playback keeps the I/O budget. Local finishing must not saturate
                // shared storage while the user has continued watching another video.
                if(playback_busy.load()) {
                    auto now=monotonic_ns();tokens=std::min(burst,tokens+(now-last_budget)/1e9*bytes_per_second);last_budget=now;
                    tokens-=packet->size;
                    while(tokens<0&&playback_busy.load()) {
                        if(cancelled.load())throw std::runtime_error("Clip export cancelled");
                        std::this_thread::sleep_for(std::chrono::milliseconds(2));
                        now=monotonic_ns();tokens=std::min(burst,tokens+(now-last_budget)/1e9*bytes_per_second);last_budget=now;
                    }
                }else {tokens=burst;last_budget=monotonic_ns();}
                av_packet_rescale_ts(packet,is_video?AVRational{1,1000000}:pcm.ctx->streams[0]->time_base,is_video?out_video->time_base:out_audio->time_base);
                packet->stream_index=is_video?0:1;packet->pos=-1;
                capture::check(av_interleaved_write_frame(output.ctx,packet));av_packet_unref(packet);
                if(is_video){have_v=false;++count;}else have_a=false;
            }
            if(count<2)throw std::runtime_error("Recording is too short");
            capture::check(av_write_trailer(output.ctx));avio_flush(output.ctx->pb);capture::check(output.ctx->pb->error);
            return "{\"state\":\"saved\",\"extension\":\"mkv\",\"start_us\":"+std::to_string(base_us)+",\"end_us\":"+std::to_string(end())+",\"video_packets\":"+std::to_string(count)+"}";
        }catch(const std::exception& problem){return "{\"state\":\"error\",\"error\":"+json_quote(problem.what())+"}";}
    }
    std::string metrics()const {
        return "{\"video_packets\":"+std::to_string(video_packets.load())+",\"audio_frames\":"+std::to_string(audio_samples.load())+
            ",\"video_queue_peak_bytes\":"+std::to_string(peak_bytes.load())+",\"lost_blocks\":"+std::to_string(lost_blocks.load())+
            ",\"callback_max_us\":"+std::to_string(callback_max_ns.load()/1000)+",\"writer_max_io_us\":"+std::to_string(io_max_ns.load()/1000)+
            ",\"source_clock_deviation_us\":"+std::to_string(clock_deviation_us.load())+"}";
    }
    std::string status() {
        std::lock_guard<std::mutex> lock(report_mutex);
        if(!error.empty())return "{\"state\":\"error\",\"error\":"+json_quote(error)+",\"capture_metrics\":"+metrics()+"}";
        return "{\"state\":\""+std::string(finished.load()?"ready":finishing.load()?"saving":"recording")+"\",\"base_us\":"+std::to_string(base_us)+",\"start_us\":"+std::to_string(begin_us)+",\"end_us\":"+std::to_string(end_us.load())+",\"audio_duration_us\":"+std::to_string(audio_duration())+",\"capture_metrics\":"+metrics()+"}";
    }
};

class Tap {
    std::mutex mutex;
    std::deque<Packet> recent;
    Codec codec;
    size_t bytes=0;
    int stream=-1;
    int64_t last_dts=AV_NOPTS_VALUE;
    std::shared_ptr<Session> active;
    std::atomic<bool> gap{false};
public:
    void invalidate(){gap.store(true);}
    void video(int index,const AVCodecParameters* params,const AVPacket* packet) noexcept {
        std::unique_lock<std::mutex> lock(mutex,std::try_to_lock);
        if(!lock.owns_lock()) {gap.store(true);auto value=std::atomic_load(&active);if(value)value->fail();return;}
        try {
            if(gap.exchange(false)){if(auto value=std::atomic_load(&active))value->fail();recent.clear();bytes=0;codec.reset();}
            if(packet->pts==AV_NOPTS_VALUE)return;
            if(stream!=index||(packet->dts!=AV_NOPTS_VALUE&&last_dts!=AV_NOPTS_VALUE&&packet->dts<last_dts)) {
                if(auto value=std::atomic_load(&active))value->fail();
                recent.clear();bytes=0;codec.reset();stream=index;
            }
            last_dts=packet->dts;
            if(packet->flags&AV_PKT_FLAG_KEY)codec=retain(params);
            if(!codec)return;
            auto copy=retain(packet);bytes+=copy->size;recent.push_back(std::move(copy));
            while(!recent.empty()&&(bytes>video_budget||packet->pts-recent.front()->pts>10000000)) {bytes-=recent.front()->size;recent.pop_front();}
            if(auto value=std::atomic_load(&active))value->push(packet);
        }catch(...){if(auto value=std::atomic_load(&active))value->fail();}
    }
    std::shared_ptr<Session> start(int64_t position,int64_t ns,bool playing,const std::string& path) {
        std::lock_guard<std::mutex> lock(mutex);
        if(gap.load())throw std::runtime_error("Keyframe unavailable for recording");
        auto first=recent.end();
        for(auto at=recent.begin();at!=recent.end();++at)if(((*at)->flags&AV_PKT_FLAG_KEY)&&(*at)->pts<=position)first=at;
        if(first==recent.end()||!codec||position-(*first)->pts>10000000)throw std::runtime_error("Keyframe unavailable for recording");
        auto result=std::make_shared<Session>(codec,(*first)->pts,position,ns,playing,path);
        for(auto at=first;at!=recent.end();++at)if(!result->push(at->get()))throw std::runtime_error("Capture writer could not keep up");
        std::atomic_store(&active,result);if(gap.load())result->fail();result->launch();return result;
    }
    void detach(){std::lock_guard<std::mutex> lock(mutex);std::atomic_store(&active,std::shared_ptr<Session>{});}
};
}
