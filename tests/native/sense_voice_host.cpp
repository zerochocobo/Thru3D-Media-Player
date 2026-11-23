// Desktop check of native/narration/sense_voice.h against sherpa-onnx.
// segments: decode the exact sherpa VAD sample ranges; texts must match.
// pipeline: project Silero v6.2 + SpeechSegmenter + SenseVoice per window.
#include "../../native/narration/sense_voice.h"
#include "json.hpp"
#include <chrono>
#include <cstring>
#include <iostream>
#include <sys/resource.h>

static std::vector<float> wav(const std::string& path){
    std::ifstream in(path,std::ios::binary);std::vector<char> bytes((std::istreambuf_iterator<char>(in)),{});
    if(bytes.size()<12||std::memcmp(bytes.data(),"RIFF",4)||std::memcmp(bytes.data()+8,"WAVE",4))throw std::runtime_error("wav "+path);
    for(size_t at=12;at+8<=bytes.size();){
        uint32_t size;std::memcpy(&size,bytes.data()+at+4,4);
        if(!std::memcmp(bytes.data()+at,"data",4)){
            std::vector<float> out(size/2);
            for(size_t i=0;i<out.size();++i){int16_t v;std::memcpy(&v,bytes.data()+at+8+2*i,2);out[i]=v/32768.f;}
            return out;
        }
        at+=8+size+(size&1);
    }
    throw std::runtime_error("wav data "+path);
}

int main(int argc,char** argv){
    if(argc<6){std::cerr<<"segments|pipeline|vad model.onnx tokens.txt audio_dir (segments.json|manifest.json) [silero.onnx]\n";return 2;}
    const std::string mode=argv[1],audio=argv[4];
    if(mode=="vad"){
        // Segments only (no recognizer): another engine decodes the same ranges.
        nlohmann::json input=nlohmann::json::parse(std::ifstream(argv[5])),out=nlohmann::json::object();
        for(auto& item:input){
            const std::string id=item["id"];auto x=wav(audio+"/"+id+".wav");SpeechSegmenter segmenter(argv[6]);
            out[id]=nlohmann::json::array();
            for(size_t at=0;at<x.size();at+=16000){const size_t n=std::min<size_t>(16000,x.size()-at);
                for(auto& seg:segmenter.accept(x.data()+at,n,at+n>=x.size()))out[id].push_back({{"start",seg.start},{"length",seg.samples.size()}});}
        }
        std::cout<<out.dump(1)<<"\n";return 0;
    }
    SenseVoice model(argv[2],argv[3],"ja");
    if(auto v=getenv("SENSE_HIGH_FREQ"))model.highFreq=std::stof(v);
    if(auto v=getenv("SENSE_LFR_PAD"))model.lfrPad=std::stoi(v);
    if(auto v=getenv("SENSE_REMOVE_DC"))model.removeDc=std::stoi(v)!=0;
    if(auto v=getenv("SENSE_LFR_RIGHT"))model.lfrRight=std::stoi(v)!=0;
    const size_t limit=getenv("SENSE_WINDOWS")?std::stoul(getenv("SENSE_WINDOWS")):1000;size_t windows=0;
    nlohmann::json input=nlohmann::json::parse(std::ifstream(argv[5])),out=nlohmann::json::object();
    double decodeSeconds=0,audioSeconds=0;
    if(mode=="segments"){
        size_t same=0,total=0;
        for(auto& [id,segments]:input.items()){
            if(windows++>=limit)break;
            auto x=wav(audio+"/"+id+".wav");audioSeconds+=x.size()/16000.;
            for(auto& s:segments){
                const size_t start=s["start"],length=s["length"];
                auto began=std::chrono::steady_clock::now();
                auto r=model.decode(x.data()+start,std::min(length,x.size()-start));
                decodeSeconds+=std::chrono::duration<double>(std::chrono::steady_clock::now()-began).count();
                const bool match=r.text==s["text"].get<std::string>();same+=match;++total;
                out[id].push_back({{"start",start},{"text",r.text},{"reference",s["text"]},{"match",match}});
            }
        }
        out["summary"]={{"segments",total},{"identical",same}};
        std::cout<<"identical "<<same<<"/"<<total<<"\n";
    }else{
        for(auto& item:input){
            const std::string id=item["id"];auto x=wav(audio+"/"+id+".wav");audioSeconds+=x.size()/16000.;
            SpeechSegmenter segmenter(argv[6]);nlohmann::json cues=nlohmann::json::array();
            if(auto v=getenv("SEG_THRESHOLD"))segmenter.threshold=std::stof(v);
            if(auto v=getenv("SEG_BEFORE"))segmenter.before=std::stoll(v);
            if(auto v=getenv("SEG_AFTER"))segmenter.after=std::stoll(v);
            if(auto v=getenv("SEG_MIN_SILENCE"))segmenter.minSilence=std::stoll(v);
            auto began=std::chrono::steady_clock::now();
            for(size_t at=0;at<x.size();at+=16000){
                const size_t n=std::min<size_t>(16000,x.size()-at);
                for(auto& seg:segmenter.accept(x.data()+at,n,at+n>=x.size())){
                    auto r=model.decode(seg.samples.data(),seg.samples.size());
                    const double a=seg.start/16000.;
                    if(!r.text.empty())cues.push_back({a,a+seg.samples.size()/16000.,r.text});
                }
            }
            decodeSeconds+=std::chrono::duration<double>(std::chrono::steady_clock::now()-began).count();
            out["windows"][id]={{"cues",cues},{"audio_seconds",x.size()/16000.},{"cpu_seconds",0.0}};
            std::cerr<<id<<" "<<cues.size()<<" cues\n";
        }
        out["config"]="native_sensevoice";
    }
    rusage usage{};getrusage(RUSAGE_SELF,&usage);
    out["timing"]={{"audio_seconds",audioSeconds},{"wall_decode_seconds",decodeSeconds},{"peak_rss_kib",usage.ru_maxrss},
        {"cpu_seconds",usage.ru_utime.tv_sec+usage.ru_utime.tv_usec/1e6+usage.ru_stime.tv_sec+usage.ru_stime.tv_usec/1e6}};
    std::cout<<out.dump(1)<<"\n";
}
