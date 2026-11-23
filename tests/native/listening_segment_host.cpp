// Production reader + Silero segment step (listening_jni.cpp) over the film-study
// windows. Writes recognized cues for research/moonshine_asr/film_score.py; the
// output contains text and stays in build/output.
#include "../../native/narration/listening_jni.cpp"
#include "json.hpp"
#include <fstream>
#include <iostream>
#include <sys/resource.h>
int main(int argc,char** argv){
    if(argc!=6){std::cerr<<"model_dir silero.onnx audio_dir manifest.json output.json\n";return 2;}
    try{
        auto e=std::make_shared<Engine>();e->vadPath=argv[2];
        e->model=listeningLoadSegmentModel(argv[1],"ja");ok(e->model);
        nlohmann::json manifest=nlohmann::json::parse(std::ifstream(argv[4])),windows=nlohmann::json::object();
        double audio=0,processing=0,maximumStep=0;
        for(auto& item:manifest){
            const std::string id=item["id"];
            e->reader=std::make_unique<AudioReader>(&e->cancelled);
            e->reader->open(std::string(argv[3])+"/"+id+".wav","",0,0,false,-1);
            e->offset=0;e->stopped=false;
            if(e->segmenter)thru3d_segmenter_destroy(e->segmenter);
            e->segmenter=thru3d_segmenter_create(e->vadPath.c_str());if(!e->segmenter)throw std::runtime_error("vad");
            nlohmann::json cues=nlohmann::json::array();
            const auto began=std::chrono::steady_clock::now();
            for(int steps=0;!e->stopped&&steps<14401;++steps){
                const auto step=std::chrono::steady_clock::now();
                auto result=nlohmann::json::parse(listening_step(e));
                maximumStep=std::max(maximumStep,std::chrono::duration<double>(std::chrono::steady_clock::now()-step).count());
                for(auto& cue:result["cues"])cues.push_back({cue["start"],cue["end"],cue["text"]});
            }
            processing+=std::chrono::duration<double>(std::chrono::steady_clock::now()-began).count();
            audio+=e->reader->cursor/16000.;
            windows[id]={{"cues",cues},{"audio_seconds",e->reader->cursor/16000.},{"cpu_seconds",0.0}};
            std::cerr<<id<<" "<<cues.size()<<" cues\n";
        }
        rusage usage{};getrusage(RUSAGE_SELF,&usage);
        std::ofstream(argv[5])<<nlohmann::json{{"config","production_segments"},{"windows",windows},
            {"timing",{{"audio_seconds",audio},{"processing_seconds",processing},{"max_step_seconds",maximumStep},{"peak_rss_kib",usage.ru_maxrss},
                {"cpu_seconds",usage.ru_utime.tv_sec+usage.ru_utime.tv_usec/1e6+usage.ru_stime.tv_sec+usage.ru_stime.tv_usec/1e6}}}}.dump();
    }catch(const std::exception& error){std::cerr<<error.what()<<'\n';return 1;}
}
