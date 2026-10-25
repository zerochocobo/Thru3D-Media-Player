#pragma once
#include "onnxruntime_cxx_api.h"
#include <memory>
#include <mutex>

// ORT's first Env controls the process environment. All clients must agree on
// global pools and register the arena once, regardless of which model opens first.
// Counted ownership frees the arena/pools after the last model owner closes.
namespace narration_ort {
struct Environment {
    Ort::ThreadingOptions threading;
    std::unique_ptr<Ort::Env> env;
    Environment() {
        threading.SetGlobalIntraOpNumThreads(2);
        threading.SetGlobalInterOpNumThreads(1);
        threading.SetGlobalSpinControl(0);
        env=std::make_unique<Ort::Env>(threading,ORT_LOGGING_LEVEL_ERROR,"thru3d-speech-ocr");
        auto info=Ort::MemoryInfo::CreateCpu(OrtArenaAllocator,OrtMemTypeDefault);
        Ort::ArenaCfg arena(0,0,4*1024*1024,0);
        env->CreateAndRegisterAllocator(info,arena);
    }
};
struct State {std::mutex gate;std::unique_ptr<Environment> environment;size_t owners=0;};
// Only this tiny registry lives for the process; it contains no model or arena
// after the final Lease. Avoid static destruction order against JNI handle maps.
inline State& state(){static State* registry=new State();return *registry;}
class Lease {
    Environment* value=nullptr;
public:
    Lease(){auto& s=state();std::lock_guard<std::mutex> guard(s.gate);
        if(!s.environment)s.environment=std::make_unique<Environment>();
        ++s.owners;value=s.environment.get();}
    ~Lease(){auto& s=state();std::lock_guard<std::mutex> guard(s.gate);
        if(--s.owners==0)s.environment.reset();}
    Lease(const Lease&)=delete;Lease& operator=(const Lease&)=delete;
    Environment* operator->()const{return value;}
};
}
