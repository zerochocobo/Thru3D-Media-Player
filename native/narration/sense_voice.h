#pragma once
#include "onnxruntime_cxx_api.h"
#include "ort_environment.h"
#include "speech_segmenter.h"
#include "kaldi-native-fbank/csrc/online-feature.h"
#include <cmath>
#include <fstream>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>
// SenseVoice-Small (FunASR model license; sherpa-onnx INT8 export) for look-ahead
// live subtitles. Offline per speech segment: the reader runs ahead of playback,
// so whole sentences are decoded at once. Front end and decoding follow
// sherpa-onnx's SenseVoice recognizer, which the desktop study measured.
class SenseVoice {
    narration_ort::Lease environment;
    Ort::SessionOptions options;
    std::unique_ptr<Ort::Session> session;
    std::vector<std::string> tokens;
    std::vector<float> negMean,invStddev;
    int lfrWindow=7,lfrShift=6,withItn=14,normalize=0;
    std::vector<float> floats(const std::string& text){
        std::vector<float> out;std::stringstream in(text);std::string item;
        while(std::getline(in,item,','))if(!item.empty())out.push_back(std::stof(item));
        return out;
    }
public:
    struct Result {std::string text;std::vector<int> ids;std::vector<float> seconds;std::string language;};
    // Language prompt ids from the export's metadata (lang_auto, lang_zh, ...).
    int language=0;
    // Front end as sherpa-onnx/FunASR (desktop check: 85% of segments decode to
    // identical text, the rest differ by a kana or punctuation): mel bins up to
    // Nyquist, DC removal, LFR padded by (window-1)/2 first frames and the last.
    float highFreq=0;int lfrPad=3;bool removeDc=true,lfrRight=true;
    SenseVoice(const std::string& model,const std::string& tokenFile,const std::string& lang){
        options.SetIntraOpNumThreads(2);options.SetInterOpNumThreads(1);
        options.AddConfigEntry("session.intra_op.allow_spinning","0");
        session=std::make_unique<Ort::Session>(*environment->env,model.c_str(),options);
        Ort::AllocatorWithDefaultOptions allocator;auto meta=session->GetModelMetadata();
        auto value=[&](const char* key){auto v=meta.LookupCustomMetadataMapAllocated(key,allocator);return v?std::string(v.get()):std::string();};
        negMean=floats(value("neg_mean"));invStddev=floats(value("inv_stddev"));
        lfrWindow=std::stoi(value("lfr_window_size"));lfrShift=std::stoi(value("lfr_window_shift"));
        withItn=std::stoi(value("with_itn"));normalize=std::stoi(value("normalize_samples"));
        language=std::stoi(value(("lang_"+lang).c_str()));
        if(negMean.size()!=size_t(80*lfrWindow)||invStddev.size()!=negMean.size())throw std::runtime_error("sense_voice_metadata");
        std::ifstream in(tokenFile);std::string line;
        while(std::getline(in,line)){auto space=line.rfind(' ');if(space==std::string::npos)throw std::runtime_error("sense_voice_tokens");
            const int id=std::stoi(line.substr(space+1));if(id!=int(tokens.size()))throw std::runtime_error("sense_voice_tokens");
            tokens.push_back(line.substr(0,space));}
    }
    /** 16 kHz mono float samples in [-1,1]; one speech segment. */
    Result decode(const float* samples,size_t count){
        knf::FbankOptions fbank;fbank.frame_opts.dither=0;fbank.frame_opts.window_type="hamming";
        fbank.frame_opts.snip_edges=true;fbank.mel_opts.num_bins=80;fbank.mel_opts.high_freq=highFreq;fbank.frame_opts.remove_dc_offset=removeDc;
        knf::OnlineFbank computer(fbank);
        // This export expects int16-scaled input (normalize_samples=0).
        const float scale=normalize?1.f:32768.f;std::vector<float> wave(samples,samples+count);
        for(auto& s:wave)s*=scale;
        computer.AcceptWaveform(16000,wave.data(),int32_t(wave.size()));computer.InputFinished();
        const int raw=computer.NumFramesReady();
        Result result;
        // FunASR's LFR: repeat the first frame lfrPad times on the left and the
        // last frame on the right so that every input frame starts an output.
        auto frameAt=[&](int i){return computer.GetFrame(std::min(raw-1,std::max(0,i-lfrPad)));};
        const int frames=raw+lfrPad;
        if(raw<=0||(!lfrRight&&frames<lfrWindow))return result;
        // Low frame rate stacking (no left padding, as sherpa-onnx), then CMVN.
        const int dim=80*lfrWindow,outFrames=lfrRight?(raw+lfrShift-1)/lfrShift:(frames-lfrWindow)/lfrShift+1;
        std::vector<float> features(size_t(outFrames)*dim);
        for(int i=0;i<outFrames;++i)for(int k=0;k<lfrWindow;++k){
            const float* frame=frameAt(i*lfrShift+k);float* out=&features[size_t(i)*dim+k*80];
            for(int j=0;j<80;++j)out[j]=(frame[j]+negMean[k*80+j])*invStddev[k*80+j];
        }
        auto memory=Ort::MemoryInfo::CreateCpu(OrtArenaAllocator,OrtMemTypeDefault);
        const int64_t xs[]{1,outFrames,dim},one[]{1};int32_t length=outFrames,lang=language,norm=withItn;
        std::array<Ort::Value,4> inputs{Ort::Value::CreateTensor<float>(memory,features.data(),features.size(),xs,3),
            Ort::Value::CreateTensor<int32_t>(memory,&length,1,one,1),Ort::Value::CreateTensor<int32_t>(memory,&lang,1,one,1),
            Ort::Value::CreateTensor<int32_t>(memory,&norm,1,one,1)};
        const char* names[]{"x","x_length","language","text_norm"};const char* outputs[]{"logits"};
        auto logits=session->Run(Ort::RunOptions{nullptr},names,inputs.data(),4,outputs,1);
        auto shape=logits[0].GetTensorTypeAndShapeInfo().GetShape();
        if(shape.size()!=3||shape[2]!=int64_t(tokens.size()))throw std::runtime_error("sense_voice_shape");
        const float* data=logits[0].GetTensorData<float>();
        // CTC greedy. The first four frames carry language/emotion/event/ITN tags.
        int previous=-1;
        for(int64_t t=0;t<shape[1];++t){
            const float* row=data+t*shape[2];int best=0;
            for(int64_t v=1;v<shape[2];++v)if(row[v]>row[best])best=int(v);
            if(best!=0&&best!=previous){
                if(t<4){if(t==0)result.language=tokens[best];}
                else {result.ids.push_back(best);result.seconds.push_back(float(t-4)*lfrShift*0.01f);}
            }
            previous=best;
        }
        for(int id:result.ids){std::string piece=tokens[id];
            for(size_t at;(at=piece.find("\xe2\x96\x81"))!=std::string::npos;)piece.replace(at,3," ");
            result.text+=piece;}
        const auto first=result.text.find_first_not_of(' ');
        result.text=first==std::string::npos?"":result.text.substr(first);
        return result;
    }
};
