// Runs only in the short lived :voice_clone process, never in the playback ORT arena.
#include "jni_text.h"
#include "onnxruntime_cxx_api.h"
#include "ort_environment.h"
#include <algorithm>
#include "voice_io.h"
extern "C" JNIEXPORT void JNICALL Java_org_vrpassthroughplayer_plugin_VoiceCloneNative_encode(JNIEnv* e,jclass,jstring model,jstring wav,jstring destination){
    try{
        auto data=voiceio::planar_wav(narration_utf8(e,wav));int32_t samples=int32_t(data.size()/2);
        narration_ort::Lease environment;Ort::SessionOptions options;
        options.SetIntraOpNumThreads(2);options.SetInterOpNumThreads(1);options.AddConfigEntry("session.intra_op.allow_spinning","0");
        Ort::Session session(*environment->env,narration_utf8(e,model).c_str(),options);auto memory=Ort::MemoryInfo::CreateCpu(OrtArenaAllocator,OrtMemTypeDefault);
        const int64_t shape[]{1,2,samples},length_shape[]{1};
        std::vector<Ort::Value> inputs;inputs.push_back(Ort::Value::CreateTensor<float>(memory,data.data(),data.size(),shape,3));
        inputs.push_back(Ort::Value::CreateTensor<int32_t>(memory,&samples,1,length_shape,1));
        const char* names[]{"waveform","input_lengths"};const char* outputs[]{"audio_codes","audio_code_lengths"};
        auto result=session.Run(Ort::RunOptions{nullptr},names,inputs.data(),2,outputs,2);
        auto code_shape=result[0].GetTensorTypeAndShapeInfo().GetShape();
        if(code_shape.size()!=3||code_shape[0]!=1||code_shape[2]!=16||result[1].GetTensorTypeAndShapeInfo().GetElementCount()!=1)throw std::runtime_error("Invalid encoder output");
        int count=result[1].GetTensorData<int32_t>()[0];if(count>code_shape[1])throw std::runtime_error("Invalid code length");
        voiceio::codes(narration_utf8(e,destination),result[0].GetTensorData<int32_t>(),count);
    }catch(const std::exception&){narration_error(e,"Unable to encode voice reference");}
}
