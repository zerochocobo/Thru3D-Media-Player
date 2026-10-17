// MOSS Nano tensor/streaming codec semantics from OpenMOSS ort_cpu_runtime.py
// 8b7bcc9341b3b4ef3a3a58ba1338a7d85ff133eb (Apache-2.0).
// Adapted from the measured local harness; no benchmark data is used at runtime.
#pragma once
#include "onnxruntime_cxx_api.h"
#include "json.hpp"
#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <deque>
#include <fstream>
#include <iostream>
#include <map>
#include <memory>
#include <mutex>
#include <numeric>
#include <stdexcept>
#include <string>
#include <sys/resource.h>
#include <sys/system_properties.h>
#include <thread>
#include <unistd.h>
#include <vector>
namespace moss {
using J = nlohmann::json;
using Clock = std::chrono::steady_clock;
double elapsed(Clock::time_point t) { return std::chrono::duration<double>(Clock::now()-t).count(); }
Ort::AllocatorWithDefaultOptions allocator;
template<class T> Ort::Value tensor(const std::vector<int64_t>& shape, T fill = T{}) {
    auto v = Ort::Value::CreateTensor<T>(allocator, shape.data(), shape.size());
    std::fill_n(v.template GetTensorMutableData<T>(), v.GetTensorTypeAndShapeInfo().GetElementCount(), fill);
    return v;
}
template<class T> Ort::Value tensor(const std::vector<int64_t>& shape, const std::vector<T>& data) {
    auto v = tensor<T>(shape);
    if (data.size() != v.GetTensorTypeAndShapeInfo().GetElementCount()) throw std::runtime_error("Tensor size mismatch");
    std::copy(data.begin(),data.end(),v.template GetTensorMutableData<T>()); return v;
}
J read_json(const std::string& p) { std::ifstream f(p); if(!f) throw std::runtime_error("Cannot read "+p); J j; f>>j; return j; }
void save_json(const std::string& p,const J& j) { std::ofstream f(p); f<<j.dump(2); if(!f) throw std::runtime_error("Cannot write "+p); }
J memory() {
    J j; std::ifstream f("/proc/self/status"); std::string line;
    while(std::getline(f,line)) for(auto k: {"VmRSS","VmHWM","VmSize","Threads"}) if(line.rfind(std::string(k)+":",0)==0) j[k]=std::stoll(line.substr(line.find(':')+1));
    std::ifstream rollup("/proc/self/smaps_rollup");
    while(std::getline(rollup,line)) for(auto k:{"Pss","Private_Clean","Private_Dirty","SwapPss"}) if(line.rfind(std::string(k)+":",0)==0) j[k]=std::stoll(line.substr(line.find(':')+1));
    return j;
}
double cpu_seconds() { rusage u{}; getrusage(RUSAGE_SELF,&u); return u.ru_utime.tv_sec+u.ru_utime.tv_usec/1e6+u.ru_stime.tv_sec+u.ru_stime.tv_usec/1e6; }
using Feeds=std::map<std::string,Ort::Value*>;
using Values=std::map<std::string,Ort::Value>;
struct Session {
    Ort::Session s;
    std::vector<std::string> output_names;
    Session(Ort::Env& env, Ort::SessionOptions& options,const std::string& path,OrtPrepackedWeightsContainer* prepacked=nullptr):s(nullptr) {
        if(prepacked)s=Ort::Session(env,path.c_str(),options,prepacked);else s=Ort::Session(env,path.c_str(),options);
        for(size_t i=0;i<s.GetOutputCount();++i) output_names.push_back(s.GetOutputNameAllocated(i,allocator).get());
    }
    Values run(const Feeds& feeds) {
        std::vector<const char*> names, outs; std::vector<const OrtValue*> inputs;
        for(auto& [name,v]:feeds) { names.push_back(name.c_str()); inputs.push_back(*v); }
        for(auto& name:output_names) outs.push_back(name.c_str());
        std::vector<OrtValue*> raw(outs.size(),nullptr);
        Ort::ThrowOnError(Ort::GetApi().Run(s,nullptr,names.data(),inputs.data(),inputs.size(),outs.data(),outs.size(),raw.data()));
        Values result; for(size_t i=0;i<raw.size();++i) result.emplace(output_names[i],Ort::Value(raw[i]));
        return result;
    }
};
Ort::Value last_hidden(const Ort::Value& src) {
    auto info=src.GetTensorTypeAndShapeInfo(); auto shape=info.GetShape();
    auto width=shape.back(); auto v=tensor<float>({1,width});
    std::copy_n(src.GetTensorData<float>()+info.GetElementCount()-width,width,v.GetTensorMutableData<float>());return v;
}
struct Codec {
    Session& session; J specs; Values states; std::map<std::string,std::string> mapping;
    Codec(Session& s,const J& config):session(s),specs(config) { reset(); }
    void reset() {
        states.clear();mapping.clear();
        for(auto& x:specs["transformer_offsets"]) {
            std::string in=x["input_name"],out=x["output_name"];
            states.emplace(in,tensor<int32_t>(x["shape"].get<std::vector<int64_t>>()));mapping[in]=out;
        }
        for(auto& x:specs["attention_caches"]) for(auto& kind: {"offset","cached_keys","cached_values","cached_positions"}) {
            std::string k=kind, in=x[k+"_input_name"],out=x[k+"_output_name"];
            std::string shape_key=k=="offset"?"offset_shape":k=="cached_positions"?"positions_shape":"cache_shape";
            auto shape=x[shape_key].get<std::vector<int64_t>>();
            if(k=="cached_keys"||k=="cached_values") states.emplace(in,tensor<float>(shape));
            else states.emplace(in,tensor<int32_t>(shape,k=="cached_positions"?-1:0));
            mapping[in]=out;
        }
    }
    std::vector<float> decode(const std::vector<int32_t>& frames,int n,int channels) {
        int count=frames.size()/n;
        auto codes=tensor<int32_t>({1,count,n},frames), length=tensor<int32_t>({1},count);
        Feeds feeds{{"audio_codes",&codes},{"audio_code_lengths",&length}};
        for(auto& [name,v]:states) feeds[name]=&v;
        auto outs=session.run(feeds);
        int samples=outs.at("audio_lengths").GetTensorData<int32_t>()[0];
        auto info=outs.at("audio").GetTensorTypeAndShapeInfo();auto shape=info.GetShape();
        if(shape.size()!=3||shape[0]!=1||shape[1]!=channels||samples<0||samples>shape[2]) throw std::runtime_error("Invalid codec shape");
        auto src=outs.at("audio").GetTensorData<float>(); std::vector<float> pcm(samples*channels);
        for(int t=0;t<samples;++t) for(int c=0;c<channels;++c) {
            float x=src[c*shape[2]+t]; if(!std::isfinite(x)) throw std::runtime_error("Nonfinite audio");
            pcm[t*channels+c]=x;
        }
        for(auto& [in,out]:mapping) states.at(in)=std::move(outs.at(out));
        return pcm;
    }
};

} // namespace moss
