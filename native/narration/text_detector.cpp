#include "text_detector.h"
#ifdef _WIN32
#define NOMINMAX
#include <windows.h>
#define ORT_API_MANUAL_INIT
#endif
#include "ort_environment.h"
#include "comic_regions.h"
#include "json.hpp"
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstring>
#include <map>
#include <mutex>
#include <stdexcept>

namespace {
using J = nlohmann::json;
struct Detector {
    narration_ort::Lease environment;
    Ort::SessionOptions options;
    std::unique_ptr<Ort::Session> session;
    std::atomic<int64_t> generation{0};
    std::mutex running;
    explicit Detector(const char* model) {
        options.SetIntraOpNumThreads(1); options.SetInterOpNumThreads(1);
        options.DisableCpuMemArena();
        options.AddConfigEntry("session.intra_op.allow_spinning", "0");
        options.AddConfigEntry("session.inter_op.allow_spinning", "0");
#ifdef _WIN32
        std::string path(model); std::wstring wide(path.begin(),path.end());
        session=std::make_unique<Ort::Session>(*environment->env,wide.c_str(),options);
#else
        session=std::make_unique<Ort::Session>(*environment->env,model,options);
#endif
    }
    J run(const float* rgb,int w,int h,int64_t token) {
        std::lock_guard<std::mutex> guard(running);
        auto check=[&]{if(generation.load()!=token)throw std::runtime_error("cancelled");};
        check();
        if(!rgb||w<32||h<32||w>1024||h>1024||w%32||h%32)throw std::runtime_error("text_input_size");
        const auto started=std::chrono::steady_clock::now();
        const size_t plane=size_t(w)*h;
        const float mean[]={.485f,.456f,.406f},sd[]={.229f,.224f,.225f};
        std::vector<float> data(plane*3);
        for(int c=0;c<3;++c)for(size_t i=0;i<plane;++i){
            const float value=rgb[(2-c)*plane+i]; // pinned Tiny expects BGR, like the existing Small detector
            if(!std::isfinite(value)||value<0||value>1)throw std::runtime_error("text_input_range");
            data[c*plane+i]=(value-mean[c])/sd[c];
        }
        std::array<int64_t,4> shape{1,3,h,w};
        auto memory=Ort::MemoryInfo::CreateCpu(OrtArenaAllocator,OrtMemTypeDefault);
        auto input=Ort::Value::CreateTensor<float>(memory,data.data(),data.size(),shape.data(),shape.size());
        Ort::AllocatorWithDefaultOptions allocator;
        auto in=session->GetInputNameAllocated(0,allocator),out=session->GetOutputNameAllocated(0,allocator);
        const char* names[]={in.get()},*outputs[]={out.get()};
        auto values=session->Run(Ort::RunOptions{nullptr},names,&input,1,outputs,1); check();
        auto dims=values[0].GetTensorTypeAndShapeInfo().GetShape();
        if(dims.size()!=4||dims[0]!=1||dims[1]!=1||dims[2]<1||dims[3]<1||dims[2]>1024||dims[3]>1024)
            throw std::runtime_error("text_output_shape");
        const int mh=int(dims[2]),mw=int(dims[3]);
        const float* scores=values[0].GetTensorData<float>();
        std::vector<uint8_t> binary(size_t(mw)*mh);
        // PP-OCRv6 Tiny's pinned inference.yml: thresh .2, box_thresh .4, unclip 1.4.
        for(size_t i=0;i<binary.size();++i)binary[i]=std::isfinite(scores[i])&&scores[i]>.2f;
        auto cc=comic::components(binary,mw,mh,scores); J boxes=J::array();
        for(size_t i=1;i<cc.regions.size()&&boxes.size()<96;++i){
            const auto& region=cc.regions[i];const auto& b=region.box;
            if(region.pixels<6||std::min(b.w(),b.h())<3||region.score<.4)continue;
            double score=0;
            for(int y=b.y0;y<b.y1;++y)for(int x=b.x0;x<b.x1;++x)score+=scores[y*mw+x];
            score/=b.area();if(!std::isfinite(score)||score<.4)continue;
            const float grow=float(1.4*b.area()/(2.*(b.w()+b.h())));
            boxes.push_back({std::max(0.f,(b.x0-grow)/mw),std::max(0.f,(b.y0-grow)/mh),
                             std::min(1.f,(b.x1+grow)/mw),std::min(1.f,(b.y1+grow)/mh),float(score)});
        }
        check();
        return {{"state","ready"},{"boxes",boxes},{"detect_ms",std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-started).count()}};
    }
};
std::mutex registry_mutex;std::map<int64_t,std::shared_ptr<Detector>> registry;std::atomic<int64_t> serial{0};
std::shared_ptr<Detector> lookup(int64_t id){std::lock_guard<std::mutex> guard(registry_mutex);auto it=registry.find(id);
    if(it==registry.end())throw std::runtime_error("closed");return it->second;}
const char* result(const J& value){auto s=value.dump();auto p=new char[s.size()+1];std::memcpy(p,s.c_str(),s.size()+1);return p;}
}
extern "C" int64_t text_detector_create(const char* model){
    try{
#ifdef _WIN32
        static std::once_flag once;std::call_once(once,[]{auto dll=LoadLibraryW(L"onnxruntime.dll");if(!dll)throw std::runtime_error("ort_unavailable");
            auto get=reinterpret_cast<const OrtApiBase*(ORT_API_CALL*)()>(GetProcAddress(dll,"OrtGetApiBase"));
            if(!get)throw std::runtime_error("ort_api");Ort::InitApi(get()->GetApi(ORT_API_VERSION));});
#endif
        auto detector=std::make_shared<Detector>(model);auto id=++serial;
        std::lock_guard<std::mutex> guard(registry_mutex);registry[id]=detector;return id;
    }catch(...){return 0;}
}
extern "C" void text_detector_cancel(int64_t id,int64_t token){try{lookup(id)->generation=token;}catch(...){}}
extern "C" const char* text_detector_run(int64_t id,const float* rgb,int w,int h,int64_t token){
    try{return result(lookup(id)->run(rgb,w,h,token));}catch(const std::exception& e){return result({{"state","error"},{"error",e.what()}});}}
extern "C" void text_detector_destroy(int64_t id){std::lock_guard<std::mutex> guard(registry_mutex);registry.erase(id);}
extern "C" void text_detector_free(const char* text){delete[] text;}
