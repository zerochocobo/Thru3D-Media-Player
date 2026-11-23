#include "moss_runtime.h"
#include "jni_text.h"
#include "sentencepiece_processor.h"
#include "pcg64.h"
#include "ort_environment.h"
#include <atomic>
#include <random>
#include <set>
#include <functional>
#include <fstream>
#include <future>

namespace moss {
// The local graph samples "continue" with probability p and stops when its draw exceeds p. INT8 flattens
// the end-of-speech peak of 1 - p to 0.2-0.7 over a few frames, so the draw misses it about 14% of the time
// on short cues and the sentence runs on. Stopping at the first frame with 1 - p >= 0.2 ended 14 of 17 such
// host cases at the spoken sentence (Whisper large-v3: 9 exact) and cut none of 57 finished clips
// mid-sentence (docs/NARRATION_THROUGHPUT_OPTIMIZATION_20261123_CN.md). Graphs without the
// continue_probability output keep the plain sampling.
constexpr float kLikelyEndProbability=0.2f;
constexpr int kLikelyEndMinimumFrames=4;
struct Engine {
    narration_ort::Lease environment;
    Ort::PrepackedWeightsContainer prepacked;
    Ort::SessionOptions options;
    std::map<std::string,std::unique_ptr<Session>> sessions;
    std::string fallback_path;
    bool fallback_available=false;
    // A voice's prompt prefix (template + reference codes) is the same for every sentence. The
    // extend graph takes several rows with a causal mask, so only the sentence's own rows run per call.
    bool extend_available=false;
    Values prefix_kv;int64_t prefix_rows=0;std::string prefix_voice;
    sentencepiece::SentencePieceProcessor tokenizer;
    J manifest, codec_meta;
    std::map<std::string,std::vector<int32_t>> personal_voices;
    std::atomic<int64_t> epoch{0};
    std::mutex running;
    explicit Engine(const std::string& root) {
        auto configure=[](Ort::SessionOptions& o) {
            o.DisablePerSessionThreads();
            o.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);
            o.AddConfigEntry("session.use_env_allocators","1");
            // Every call is batch 1: fixed shapes let ORT fold the shape arithmetic.
            o.AddFreeDimensionOverrideByName("batch",1);
            o.AddConfigEntry("session.intra_op.allow_spinning","0"); o.AddConfigEntry("session.inter_op.allow_spinning","0");
        };
        configure(options);
        // The frame loop runs one row per decode step. Bit-identical; on the host it saved only a few
        // percent (decode step ~6% at best, local frame within noise).
        options.AddFreeDimensionOverrideByName("step_seq",1);
        Ort::SessionOptions extend_options;configure(extend_options);
        const std::string t=root+"/MOSS-TTS-Nano-100M-ONNX/", c=root+"/MOSS-Audio-Tokenizer-Nano-ONNX/";
        manifest=read_json(t+"browser_poc_manifest.json"); codec_meta=read_json(c+"codec_browser_onnx_meta.json");
        fallback_path=t+"moss_tts_local_fallback.onnx";
        fallback_available=std::ifstream(fallback_path).good();
        const std::string extend_path=t+"moss_tts_extend.onnx";
        extend_available=std::ifstream(extend_path).good();
        if(!tokenizer.Load(t+"tokenizer.model").ok()) throw std::runtime_error("Tokenizer unavailable");
        // Two loaders only. ORT 1.28 serializes shared prepack access internally;
        // graph parsing/optimization can overlap without duplicating weights.
        // The future joins on exceptions before environment/options can be freed.
        auto local=std::async(std::launch::async,[&,path=t+"moss_tts_local_fixed_sampled_frame.onnx"] {
            auto local_options=options.Clone();
            return std::make_unique<Session>(*environment->env,local_options,path,static_cast<OrtPrepackedWeightsContainer*>(prepacked));
        });
        std::future<std::unique_ptr<Session>> extend;
        if(extend_available)extend=std::async(std::launch::async,[&,extend_path] {
            auto clone=extend_options.Clone();
            return std::make_unique<Session>(*environment->env,clone,extend_path,static_cast<OrtPrepackedWeightsContainer*>(prepacked));
        });
        for (auto item : {std::pair{"prefill",t+"moss_tts_prefill.onnx"}, {"decode",t+"moss_tts_decode_step.onnx"},
                          {"codec",c+"moss_audio_tokenizer_decode_step.onnx"}})
            sessions[item.first]=std::make_unique<Session>(*environment->env,options,item.second,static_cast<OrtPrepackedWeightsContainer*>(prepacked));
        sessions["local"]=local.get();
        if(extend_available) {
            // An unreadable optional graph falls back to the full prefill instead of failing the engine.
            try {sessions["extend"]=extend.get();} catch(const std::exception&) {extend_available=false;}
        }
    }
    J generate(const std::string& text,const std::string& voice,int64_t token, const std::function<bool(const std::vector<float>&)>& output, int max_frames=250, int random_skip=0, bool precision_recovery=false) {
        std::lock_guard<std::mutex> lock(running);
        auto cancelled=[&]{return epoch.load()!=token;};
        if(cancelled()) return {{"cancelled",true}};
        const std::set<std::string> allowed{"Xiaoyu","Zhiming","Ava","Adam","Mei","Umiri","Yuewen","Junhao","Lingyu","Bella","Saki","Mortis"};
        if(text.empty()||text.size()>4096||(!allowed.count(voice)&&!personal_voices.count(voice))) throw std::runtime_error("Invalid narration input");
        if(max_frames<1||max_frames>250||random_skip<0||random_skip>1024)throw std::runtime_error("Invalid synthesis limits");
        std::vector<int> tokens;
        if(!tokenizer.Encode(text,&tokens).ok()||tokens.empty()||tokens.size()>384) throw std::runtime_error("Narration text too long");
        const auto& cfg=manifest["tts_config"]; const auto& tpl=manifest["prompt_templates"];
        const int n=16,book=1024,pad=cfg["audio_pad_token_id"],slot=cfg["audio_assistant_slot_token_id"];
        std::vector<int32_t> flat;
        auto text_row=[&](int32_t id) { flat.push_back(id);flat.insert(flat.end(),n,pad); };
        for(int32_t id:tpl["user_prompt_prefix_token_ids"]) text_row(id);
        text_row(cfg["audio_start_token_id"]);
        bool found=false;
        auto personal=personal_voices.find(voice);
        if(personal!=personal_voices.end()) {
            const auto& codes=personal->second;
            for(size_t frame=0;frame<codes.size();frame+=n) {
                flat.push_back(cfg["audio_user_slot_token_id"]);
                flat.insert(flat.end(),codes.begin()+frame,codes.begin()+frame+n);
            }
            found=true;
        }
        for(const auto& v:manifest["builtin_voices"]) if(v["voice"]==voice) {
            for(const auto& row:v["prompt_audio_codes"]) { flat.push_back(cfg["audio_user_slot_token_id"]); for(int i=0;i<n;++i) flat.push_back(row[i]); }
            found=true;break;
        }
        if(!found) throw std::runtime_error("Voice preset unavailable");
        text_row(cfg["audio_end_token_id"]);
        for(int32_t id:tpl["user_prompt_after_reference_token_ids"]) text_row(id);
        const size_t prefix_values=flat.size();
        for(int32_t id:tokens) text_row(id);
        for(int32_t id:tpl["assistant_prompt_prefix_token_ids"]) text_row(id);
        text_row(cfg["audio_start_token_id"]);
        int valid=flat.size()/(n+1);
        auto ids=tensor<int32_t>({1,valid,n+1},flat),mask=tensor<int32_t>({1,valid},1);
        auto started=Clock::now(); double first=-1;int frames=0;bool eos=false;
        const bool recovery=precision_recovery&&fallback_available;
        double recovery_load_seconds=0;int probability_stops=0;
        if(recovery&&!sessions.count("local_fallback")) {
            auto load_started=Clock::now();
            sessions["local_fallback"]=std::make_unique<Session>(*environment->env,options,fallback_path,static_cast<OrtPrepackedWeightsContainer*>(prepacked));
            recovery_load_seconds=elapsed(load_started);
        }
        if(cancelled())return {{"cancelled",true}};
        auto& local_session=sessions.at(recovery?"local_fallback":"local");
        Values outputs;bool prefix_hit=false;
        const int prefix_len=int(prefix_values/(n+1));
        auto prefill_started=Clock::now();
        if(extend_available) {
            try {
                if(prefix_voice!=voice||prefix_rows!=prefix_len||prefix_kv.empty()) {
                    prefix_kv.clear();prefix_voice.clear();
                    std::vector<int32_t> head(flat.begin(),flat.begin()+prefix_values);
                    auto head_ids=tensor<int32_t>({1,prefix_len,n+1},head),head_mask=tensor<int32_t>({1,prefix_len},1);
                    auto head_out=sessions.at("prefill")->run({{"input_ids",&head_ids},{"attention_mask",&head_mask}});
                    Values cache;
                    for(auto& [name,value]:head_out)if(name.rfind("present_",0)==0)cache.emplace("past_"+name.substr(8),std::move(value));
                    prefix_kv=std::move(cache);prefix_rows=prefix_len;prefix_voice=voice;
                } else prefix_hit=true;
                if(cancelled())return {{"cancelled",true}};
                std::vector<int32_t> rest(flat.begin()+prefix_values,flat.end());
                auto rest_ids=tensor<int32_t>({1,int64_t(rest.size()/(n+1)),n+1},rest),past_length=tensor<int32_t>({1},prefix_len);
                Feeds extend_feeds{{"input_ids",&rest_ids},{"past_valid_lengths",&past_length}};
                for(auto& [name,value]:prefix_kv)extend_feeds[name]=&value;
                outputs=sessions.at("extend")->run(extend_feeds);
            } catch(const std::exception&) {
                // Never lose a sentence to the cache: drop it, stop using it, run the full prefill below.
                extend_available=false;prefix_kv.clear();prefix_voice.clear();outputs.clear();prefix_hit=false;
            }
        }
        if(outputs.empty())outputs=sessions.at("prefill")->run({{"input_ids",&ids},{"attention_mask",&mask}});
        const double prefill_seconds=elapsed(prefill_started);
        auto hidden=last_hidden(outputs.at("global_hidden"));
        std::vector<int32_t> seen(n*book,0),pending;
        Codec codec(*sessions.at("codec"),codec_meta["streaming_decode"]);
        Pcg64 random;
        for(int i=0;i<random_skip;++i)random.next();
        auto emit=[&] {
            if(pending.empty()||cancelled()) return;
            auto block=codec.decode(pending,n,2);pending.clear();
            if(first<0)first=elapsed(started);
            if(!output(block)) {int64_t expected=token;epoch.compare_exchange_strong(expected,token+1);}
        };
        for(int step=0;step<max_frames&&!cancelled();++step) {
            float assistant_random=random.next();std::vector<float> draws(n);for(auto& x:draws)x=random.next();
            auto seen_tensor=tensor<int32_t>({1,n,book},seen),ar=tensor<float>({1},assistant_random),au=tensor<float>({1,n},draws);
            auto local=local_session->run({{"global_hidden",&hidden},{"repetition_seen_mask",&seen_tensor},{"assistant_random_u",&ar},{"audio_random_u",&au}});
            const auto probability=local.find("continue_probability");
            const bool likely_end=probability!=local.end()&&frames>=kLikelyEndMinimumFrames&&
                1.0f-probability->second.GetTensorData<float>()[0]>=kLikelyEndProbability;
            if(local.at("should_continue").GetTensorData<int32_t>()[0]==0||likely_end) {eos=true;if(likely_end&&local.at("should_continue").GetTensorData<int32_t>()[0]!=0)++probability_stops;break;}
            auto codes=local.at("frame_token_ids").GetTensorData<int32_t>();
            if(local.at("frame_token_ids").GetTensorTypeAndShapeInfo().GetElementCount()!=size_t(n))throw std::runtime_error("Invalid audio tokens");
            std::vector<int32_t> row(n+1,pad);row[0]=slot;
            for(int i=0;i<n;++i) {if(codes[i]<0||codes[i]>=book)throw std::runtime_error("Invalid audio token");seen[i*book+codes[i]]=1;row[i+1]=codes[i];pending.push_back(codes[i]);}
            ++frames;
            auto next=tensor<int32_t>({1,1,n+1},row),length=tensor<int32_t>({1},valid);
            Feeds feeds{{"input_ids",&next},{"past_valid_lengths",&length}};
            for(auto& [out,value]:outputs)if(out.rfind("present_",0)==0)feeds["past_"+out.substr(8)]=&value;
            auto next_outputs=sessions.at("decode")->run(feeds);hidden=last_hidden(next_outputs.at("global_hidden"));outputs=std::move(next_outputs);++valid;
            if(pending.size()>=size_t(4*n))emit();
        }
        emit();
        return {{"cancelled",cancelled()},{"eos",eos},{"audio_seconds",frames*0.08},{"first_audio_seconds",first},{"wall_seconds",elapsed(started)},
                {"probability_stop",probability_stops>0},{"prefix_cached",extend_available},{"prefix_hit",prefix_hit},{"prefill_seconds",prefill_seconds},
                {"precision_recovery",recovery},{"precision_recovery_available",fallback_available},{"precision_model_loaded",sessions.count("local_fallback")>0},{"precision_load_seconds",recovery_load_seconds}};
    }
};
std::mutex engines_mutex;
std::map<int64_t,std::shared_ptr<Engine>> engines;
int64_t next_engine=0;
std::shared_ptr<Engine> engine(int64_t id) {
    std::lock_guard<std::mutex> lock(engines_mutex);auto it=engines.find(id);
    if(it==engines.end())throw std::runtime_error("Narration engine unavailable");return it->second;
}
}
extern "C" JNIEXPORT jlong JNICALL Java_org_vrpassthroughplayer_plugin_NarrationNative_create(JNIEnv* e,jclass,jstring path) {
    try {auto engine=std::make_shared<moss::Engine>(narration_utf8(e,path));std::lock_guard<std::mutex> lock(moss::engines_mutex);auto id=++moss::next_engine;moss::engines[id]=engine;return id;}
    catch(const std::exception&) {narration_error(e,"Unable to load narration model");return 0;}
}
extern "C" JNIEXPORT void JNICALL Java_org_vrpassthroughplayer_plugin_NarrationNative_cancel(JNIEnv* e,jclass,jlong id,jlong epoch) {
    try {moss::engine(id)->epoch.store(epoch);} catch(const std::exception&) {narration_error(e,"Narration engine unavailable");}
}
extern "C" JNIEXPORT void JNICALL Java_org_vrpassthroughplayer_plugin_NarrationNative_destroy(JNIEnv*,jclass,jlong id) {
    std::lock_guard<std::mutex> lock(moss::engines_mutex);moss::engines.erase(id);
}
extern "C" JNIEXPORT void JNICALL Java_org_vrpassthroughplayer_plugin_NarrationNative_registerVoice(JNIEnv* e,jclass,jlong id,jstring name,jintArray codes) {
    try {
        auto key=narration_utf8(e,name);auto size=e->GetArrayLength(codes);
        if(key.rfind("custom:",0)!=0||key.size()>64||size<37*16||size>125*16||size%16)throw std::runtime_error("Invalid voice");
        std::vector<int32_t> values(size);e->GetIntArrayRegion(codes,0,size,values.data());if(e->ExceptionCheck())return;
        if(!std::all_of(values.begin(),values.end(),[](int32_t x){return x>=0&&x<1024;}))throw std::runtime_error("Invalid codes");
        auto engine=moss::engine(id);std::lock_guard<std::mutex> lock(engine->running);
        engine->personal_voices.clear();engine->personal_voices.emplace(key,std::move(values));
        engine->prefix_kv.clear();engine->prefix_voice.clear();
    } catch(const std::exception&) {narration_error(e,"Unable to load personal voice");}
}
static jstring narration_synthesize(JNIEnv* e,jlong id,jstring text,jstring voice,jlong epoch,jobject sink,int max_frames,int random_skip,bool precision_recovery=false) {
    try {
        auto type=e->GetObjectClass(sink);auto method=e->GetMethodID(type,"onChunk","(J[F)Z");e->DeleteLocalRef(type);
        if(!method||e->ExceptionCheck())return nullptr;
        auto result=moss::engine(id)->generate(narration_utf8(e,text),narration_utf8(e,voice),epoch,[&](const std::vector<float>& block) {
            auto array=e->NewFloatArray(block.size());if(!array)return false;
            e->SetFloatArrayRegion(array,0,block.size(),block.data());bool accepted=e->CallBooleanMethod(sink,method,epoch,array);e->DeleteLocalRef(array);
            return !e->ExceptionCheck()&&accepted;
        },max_frames,random_skip,precision_recovery);
        if(e->ExceptionCheck())return nullptr;
        return e->NewStringUTF(result.dump(-1,' ',true).c_str());
    } catch(const std::exception&) {narration_error(e,"Narration synthesis failed");return nullptr;}
}
extern "C" JNIEXPORT jstring JNICALL Java_org_vrpassthroughplayer_plugin_NarrationNative_synthesize(JNIEnv* e,jclass,jlong id,jstring text,jstring voice,jlong epoch,jobject sink) {
    return narration_synthesize(e,id,text,voice,epoch,sink,250,0);
}
extern "C" JNIEXPORT jstring JNICALL Java_org_vrpassthroughplayer_plugin_NarrationNative_synthesizeConfigured(JNIEnv* e,jclass,jlong id,jstring text,jstring voice,jlong epoch,jint max_frames,jint random_skip,jobject sink) {
    return narration_synthesize(e,id,text,voice,epoch,sink,max_frames,random_skip);
}
extern "C" JNIEXPORT jstring JNICALL Java_org_vrpassthroughplayer_plugin_NarrationNative_synthesizePrecisionConfigured(JNIEnv* e,jclass,jlong id,jstring text,jstring voice,jlong epoch,jint max_frames,jint random_skip,jboolean precision_recovery,jobject sink) {
    return narration_synthesize(e,id,text,voice,epoch,sink,max_frames,random_skip,precision_recovery==JNI_TRUE);
}
