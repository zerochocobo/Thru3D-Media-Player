#include "live_capture_core.h"
#include "../capture_audio_layout.h"
#include <filesystem>
#include <iostream>

using namespace quest::live;
static Audio signal(int frame,int frames,int rate) {
    Audio audio;audio.owner=1;audio.frames=frames;audio.rate=rate;audio.channels=2;audio.format=1;
    for(int i=0;i<frames;++i) {
        const float value=.15f+.05f*std::sin((frame+i)*440.*6.283185307179586/rate);
        std::memcpy(audio.bytes.data()+i*8,&value,4);std::memcpy(audio.bytes.data()+i*8+4,&value,4);
    }
    return audio;
}
static std::vector<float> read(const std::string& path,int header=80) {
    std::unique_ptr<FILE,FileClose> file(std::fopen(path.c_str(),"rb"));
    if(!file)throw std::runtime_error("Missing audio fixture");
    std::fseek(file.get(),0,SEEK_END);auto size=std::ftell(file.get());std::fseek(file.get(),header,SEEK_SET);
    std::vector<float> values((size-header)/4);
    if(std::fread(values.data(),sizeof(float),values.size(),file.get())!=values.size())throw std::runtime_error("Short WAV fixture");
    return values;
}
int main(int argc,char** argv) {
    if(argc!=2)return 2;
    try {
        std::filesystem::create_directories(argv[1]);
        const auto path=std::string(argv[1])+"/jitter.wav";
        const int64_t ns=10000000000;
        PresentedAudio device;
        {Wave wave(path);
         for(int part=0;part<250;++part) {
             const int frame=part*192;auto audio=signal(frame,192,48000);
             if(!device.submit(audio,frame))throw std::runtime_error("Device history full");
             const int64_t jitter=part==0?0:((part*37)%31-15)*20000;
             device.present(frame+192,ns+(frame+192)*1000000000LL/48000+jitter,
                 [&](const Audio& output){wave.add(output,{ns,0,true},0,ns,INT64_MAX);});
         }
         wave.finish(48000);}
        auto actual=read(path);size_t bad=0,zero=0;double max_error=0;
        for(int frame=0;frame<48000;++frame) {
            const auto expected=signal(frame,1,48000);float value;std::memcpy(&value,expected.bytes.data(),4);
            const auto error=std::abs(actual[frame*2]-value);max_error=std::max(max_error,static_cast<double>(error));
            if(error>1e-6)++bad;
            if(actual[frame*2]==0)++zero;
        }
        std::cout<<"{\"jitter_mismatched_frames\":"<<bad<<",\"inserted_zero_frames\":"<<zero<<",\"max_error\":"<<max_error<<"}\n";
        if(bad)throw std::runtime_error("Timestamp jitter changed continuous played PCM");
        // Resetting only the capture clock at a real underrun must preserve
        // the actual gap and keep the next, already submitted samples.
        PresentedAudio gap;auto first_audio=signal(0,480,48000),last_audio=signal(480,480,48000);
        if(!gap.submit(first_audio,0)||!gap.submit(last_audio,480))throw std::runtime_error("Gap fixture submit");
        int64_t first_ns=-1,last_ns=-1;int frames=0;
        gap.present(480,ns+10000000,[&](const Audio& a){first_ns=a.ns;frames+=a.frames;});
        gap.discontinuity();
        gap.present(960,ns+120000000,[&](const Audio& a){last_ns=a.ns;frames+=a.frames;});
        if(first_ns!=ns||last_ns!=ns+110000000||frames!=960)throw std::runtime_error("Real heard gap was changed");
        // Non-48k source blocks must cover adjacent output endpoints exactly,
        // rather than rounding each block length independently.
        const auto converted_path=std::string(argv[1])+"/44100.wav";
        {Wave wave(converted_path);PresentedAudio device44;
         for(int frame=0;frame<44100;frame+=192) {
             const int count=std::min(192,44100-frame);auto a=signal(frame,count,44100);
             std::array<float,2048> constant;constant.fill(.125f);std::memcpy(a.bytes.data(),constant.data(),count*8);
             if(!device44.submit(a,frame))throw std::runtime_error("44100 submit");
             device44.present(frame+count,ns+(frame+count)*1000000000LL/44100,[&](const Audio& output){wave.add(output,{ns,0,true},0,ns,INT64_MAX);});
         }
         wave.finish(48000);}
        auto converted=read(converted_path);
        for(auto value:converted)if(std::abs(value-.125f)>1e-6)throw std::runtime_error("Resampled block endpoints inserted a hole or overlap");
        for(int channels:{2,6,8})for(int format:{1,2,3}) {
            const uint64_t layout=channels==6?0x60f:channels==8?0x63f:3;
            const auto file=std::string(argv[1])+"/channels-"+std::to_string(channels)+"-format-"+std::to_string(format)+".wav";
            Audio source;source.owner=1;source.ns=ns;source.rate=48000;source.frames=480;
            source.channels=channels;source.layout=layout;source.format=format;
            for(int frame=0;frame<480;++frame)for(int channel=0;channel<channels;++channel) {
                const float value=(channel+1)/32.f;const int at=frame*channels+channel;
                if(format==1)std::memcpy(source.bytes.data()+at*4,&value,4);
                else if(format==2){const auto integer=static_cast<int16_t>(value*32768);std::memcpy(source.bytes.data()+at*2,&integer,2);}
                else {const auto integer=static_cast<int32_t>(double(value)*2147483648.);std::memcpy(source.bytes.data()+at*4,&integer,4);}
            }
            auto speech=signal(0,480,48000);speech.owner=2;speech.ns=ns;
            std::array<float,960> voice;voice.fill(.125f);std::memcpy(speech.bytes.data(),voice.data(),sizeof(voice));
            {Wave wave(file,layout);wave.add(source,{ns,0,true},0,ns,INT64_MAX);wave.add(speech,{ns,0,true},0,ns,INT64_MAX);wave.finish(480);}
            const auto values=read(file,channels>2?104:80);
            if(values.size()!=size_t(480*channels))throw std::runtime_error("Multichannel PCM length changed");
            for(int frame=0;frame<480;++frame)for(int channel=0;channel<channels;++channel)
                if(std::abs(values[frame*channels+channel]-((channel+1)/32.f+(channel<2?.125f:0.f)))>1e-6)
                    throw std::runtime_error("Surround channel or stereo narration lost/remapped");
        }
        const auto filter=quest::capture::audio_layout_filter("1551",6);
        if(filter.find("map=0|1|2|3|4|5:channel_layout=0x60f")==std::string::npos||
           !quest::capture::audio_layout_filter("1551",2).empty()||
           !quest::capture::audio_layout_filter("1551:volume=0",6).empty()||
           !quest::capture::audio_layout_filter("99999999999999999999",6).empty())
            throw std::runtime_error("Recorded speaker mask validation failed");
        std::cout<<"{\"real_gap_preserved\":true,\"resampled_44100_holes\":0}\n";
        std::cout<<"{\"pcm_formats\":[1,2,3],\"channel_layouts\":[\"stereo\",\"5.1(side)\",\"7.1\"],\"all_channels_and_narration_preserved\":true}\n";
        return 0;
    }catch(const std::exception& failure){std::cerr<<failure.what()<<'\n';return 1;}
}
