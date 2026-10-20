// Host executable exercises exactly the Android queue, WAV mixer, GOP and mux core.
#include "live_capture_core.h"
#include <iostream>
#include <cassert>
#include <set>
#include <filesystem>

int main(int argc,char** argv) {
    if(argc!=4&&argc!=5)return 2;
    const bool normal=argc==5&&std::string(argv[4])=="normal";
    try {
        quest::live::Queue<int,4> queue;
        for(int i=0;i<4;++i)assert(queue.offer([&](int& value){value=i;}));
        assert(!queue.offer([](int& value){value=5;}));
        for(int i=0;i<4;++i){int value=-1;assert(queue.take(value)&&value==i);}
        int empty=0;assert(!queue.take(empty));
        quest::live::Queue<int,64> concurrent;
        std::vector<std::thread> producers;
        for(int owner=0;owner<3;++owner)producers.emplace_back([&,owner]{for(int i=0;i<10000;++i){
            while(!concurrent.offer([&](int& value){value=owner*10000+i;}))std::this_thread::yield();}});
        std::vector<bool> seen(30000,false);
        for(int count=0;count<30000;){int value=0;if(concurrent.take(value)){
            assert(value>=0&&value<30000&&!seen[value]);seen[value]=true;++count;}else std::this_thread::yield();}
        for(auto& producer:producers)producer.join();
        quest::live::PresentedAudio presented;
        quest::live::Audio submitted;submitted.frames=100;submitted.channels=2;submitted.rate=48000;submitted.format=1;
        assert(presented.submit(submitted,0));int heard=0;
        presented.present(40,1000000000,[&](const quest::live::Audio& value){heard+=value.frames;});assert(heard==40);
        presented.reset();presented.present(100,2000000000,[&](const quest::live::Audio& value){heard+=value.frames;});assert(heard==40);
        for(int i=0;i<64;++i)assert(presented.submit(submitted,i*100));
        assert(!presented.submit(submitted,6400));presented.reset();
        // 1024 frames has a fractional nanosecond duration at 48 kHz. Rounding
        // timestamps down twice must not silently erase the last sample of each block.
        const auto boundary_path=std::string(argv[2])+".boundary.wav";
        {quest::live::Wave wave(boundary_path);quest::live::Audio audio;
         audio.owner=1;audio.ns=1000000000;audio.frames=1024;audio.rate=48000;audio.channels=2;audio.format=1;
         std::array<float,2048> signal;signal.fill(.5f);std::memcpy(audio.bytes.data(),signal.data(),sizeof(signal));
         wave.add(audio,{audio.ns,0,true},0,audio.ns,INT64_MAX);wave.finish(1024);}
        {auto* file=std::fopen(boundary_path.c_str(),"rb");assert(file);assert(!std::fseek(file,80,SEEK_SET));
         std::array<float,2048> actual{};assert(std::fread(actual.data(),sizeof(float),actual.size(),file)==actual.size());
         std::fclose(file);for(auto value:actual)assert(value==.5f);}
        quest::capture::Control control;quest::capture::Input input;input.open(argv[1],"",control);
        int index=av_find_best_stream(input.ctx,AVMEDIA_TYPE_VIDEO,-1,-1,nullptr,0);quest::capture::check(index);
        auto* stream=input.ctx->streams[index];
        auto codec=quest::live::retain(stream->codecpar);
        if(codec->framerate.num<=0)codec->framerate=stream->avg_frame_rate;
        std::vector<quest::live::Packet> packets;auto packet=quest::capture::packet();
        while(av_read_frame(input.ctx,packet.get())>=0) {
            if(packet->stream_index==index){auto copy=quest::live::retain(packet.get());
                av_packet_rescale_ts(copy.get(),stream->time_base,AVRational{1,1000000});packets.push_back(std::move(copy));}
            av_packet_unref(packet.get());
        }
        auto fingerprint=[](const AVPacket& value){uint64_t hash=1469598103934665603ULL;
            for(int i=0;i<value.size;++i){hash^=value.data[i];hash*=1099511628211ULL;}return hash;};
        std::vector<uint64_t> hashes;std::vector<int64_t> pts,dts;
        for(const auto& value:packets){hashes.push_back(fingerprint(*value));pts.push_back(value->pts);dts.push_back(value->dts);}
        avformat_close_input(&input.ctx);
        const std::filesystem::path source_path(argv[1]),stage_path(argv[2]);
        if(source_path.filename()!="live-input.mp4"||source_path.parent_path()!=stage_path.parent_path())throw std::runtime_error("Use the owned live-input.mp4 fixture copy");
        // Deliberately remove only this regenerable test copy before recording stops.
        if(!std::filesystem::remove(source_path))throw std::runtime_error("Could not close fixture source");
        quest::live::Tap tap;size_t next=0;
        while(next<packets.size()&&packets[next]->dts<2500000)tap.video(index,codec.get(),packets[next++].get());
        const auto ns=quest::live::monotonic_ns();
        auto session=tap.start(2500000,ns,true,argv[2]);
        std::vector<float> normal_reference(static_cast<size_t>((session->begin_us-session->base_us)*96000/1000000),0.f);
        session->clock(ns+500000000,2800000,true); // Simulated displayed-frame jitter must not erase or overlap heard words.
        session->clock(ns+1000000000,3500000,false);
        session->clock(ns+2000000000,3500000,true);
        session->clock(ns+3000000000,4500000,true);
        while(next<packets.size()&&packets[next]->dts<4600000)tap.video(index,codec.get(),packets[next++].get());
        // 3 seconds actually heard with a one-second video pause removed, no re-synthesis.
        for(int part=0;part<150;++part) {
            // Deliver the synthetic trace at its real device cadence. Bursting
            // three seconds in 60 ms tests queue overflow, not recording quality.
            std::this_thread::sleep_until(std::chrono::steady_clock::time_point(std::chrono::nanoseconds(ns+part*20000000LL)));
            if(normal&&part>=50&&part<100)continue;
            quest::live::Audio audio;audio.owner=1;audio.frames=960;audio.rate=48000;audio.channels=2;audio.format=1;
            audio.ns=ns+part*20000000LL;
            std::array<float,1920> data{};
            if(normal) {
                // A normal player's output, with no narration controller or TTS callback.
                for(int frame=0;frame<960;++frame) {
                    const auto number=(part<50?part:part-50)*960+frame;
                    const float value=static_cast<float>(.1*std::sin(number*440.0*6.283185307179586/48000)+.03*std::sin(number*2053.0*6.283185307179586/48000));
                    data[frame*2]=data[frame*2+1]=value;
                }
                std::memcpy(audio.bytes.data(),data.data(),sizeof(data));
                auto before=audio.bytes;session->push(audio);assert(before==audio.bytes);
                for(auto value:data)normal_reference.push_back(value);
            } else {
                data.fill(.125f);std::memcpy(audio.bytes.data(),data.data(),sizeof(data));session->push(audio);
                audio.owner=2;audio.gain=.5f;
                data.fill(part>=110&&part<120?0.f:.25f);std::memcpy(audio.bytes.data(),data.data(),sizeof(data));session->push(audio);
            }
        }
        tap.detach();session->stop(4500000,ns+3000000000);
        for(int i=0;i<5000&&!session->done();++i)std::this_thread::sleep_for(std::chrono::milliseconds(2));
        std::cout<<session->status()<<'\n';
        if(session->status().find("\"ready\"")==std::string::npos)return 1;
        const auto result=session->export_file(argv[3],"{\"version\":1,\"geometry\":3}");
        for(size_t i=0;i<packets.size();++i)assert(hashes[i]==fingerprint(*packets[i])&&pts[i]==packets[i]->pts&&dts[i]==packets[i]->dts);
        if(normal) {
            auto* reference=std::fopen((std::string(argv[2])+".reference.f32").c_str(),"wb");assert(reference);
            assert(std::fwrite(normal_reference.data(),sizeof(float),normal_reference.size(),reference)==normal_reference.size());std::fclose(reference);
        }
        std::cout<<result<<'\n';
        return result.find("\"saved\"")==std::string::npos?1:0;
    }catch(const std::exception& failure){std::cerr<<failure.what()<<'\n';return 1;}
}
