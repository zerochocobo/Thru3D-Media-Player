#pragma once
#include "onnxruntime_cxx_api.h"
#include "ort_environment.h"
#include <array>
#include <algorithm>
// Silero v6.2 streaming ABI; pinned model and license in third_party/narration.
// 512 new 16kHz samples, 64 context samples, independent recurrent state per scan.
class VoiceVad {
    narration_ort::Lease environment;
    Ort::SessionOptions options;
    std::unique_ptr<Ort::Session> session;
    std::array<float,576> input{};
    std::array<float,256> state{};
public:
    explicit VoiceVad(const char* path) {
        options.SetIntraOpNumThreads(1);options.SetInterOpNumThreads(1);
        options.AddConfigEntry("session.intra_op.allow_spinning","0");
        session=std::make_unique<Ort::Session>(*environment->env,path,options);
    }
    void reset() {input.fill(0);state.fill(0);}
    float run(const float* samples) {
        std::copy_n(samples,512,input.begin()+64);
        auto memory=Ort::MemoryInfo::CreateCpu(OrtArenaAllocator,OrtMemTypeDefault);
        const int64_t xs[]{1,576},ss[]{2,1,128};int64_t rate=16000;
        std::array<Ort::Value,3> tensors{
            Ort::Value::CreateTensor<float>(memory,input.data(),input.size(),xs,2),
            Ort::Value::CreateTensor<float>(memory,state.data(),state.size(),ss,3),
            Ort::Value::CreateTensor<int64_t>(memory,&rate,1,nullptr,0)};
        const char* names[]{"input","state","sr"};const char* outputs[]{"output","stateN"};
        auto result=session->Run(Ort::RunOptions{nullptr},names,tensors.data(),3,outputs,2);
        if(result[0].GetTensorTypeAndShapeInfo().GetElementCount()!=1||result[1].GetTensorTypeAndShapeInfo().GetElementCount()!=256)
            throw std::runtime_error("voice_vad_shape");
        std::copy_n(result[1].GetTensorData<float>(),256,state.begin());
        std::copy(input.end()-64,input.end(),input.begin());
        return result[0].GetTensorData<float>()[0];
    }
};
