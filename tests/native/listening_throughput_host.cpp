// Unpaced whole-source benchmark of the production reader and ASR step.
// Never prints paths or recognized text. Desktop results are not headset claims.
#include "../../native/narration/listening_jni.cpp"
#include <iostream>
#include <sys/resource.h>
int main(int argc,char** argv){
    if(argc!=5)return 2;
    try{
        const auto started=std::chrono::steady_clock::now();
        auto e=std::make_shared<Engine>();
        e->model=listeningLoadModel(argv[1],argv[2]);ok(e->model);
        const auto loaded=std::chrono::steady_clock::now();
        e->reader=std::make_unique<AudioReader>(&e->cancelled);
        e->reader->open(argv[3],"",std::stoi(argv[4]),0,false,-1);
        e->stream=moonshine_create_stream(e->model,0);ok(e->stream);ok(moonshine_start_stream(e->model,e->stream));
        const auto opened=std::chrono::steady_clock::now();
        double readMs=0,inferenceMs=0,maximumStepMs=0;int steps=0;
        // Extract numeric timing fields without retaining subtitle strings.
        auto number=[](const std::string& value,const char* key){auto at=value.find(key);if(at==std::string::npos)throw std::runtime_error("missing_metric");return std::stod(value.substr(at+std::char_traits<char>::length(key)));};
        for(;!e->stopped&&steps<14401;++steps){
            const auto began=std::chrono::steady_clock::now();
            auto result=listening_step(e);
            readMs+=number(result,"\"read_ms\":");inferenceMs+=number(result,"\"inference_ms\":");
            maximumStepMs=std::max(maximumStepMs,std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-began).count());
            if((steps+1)%60==0)std::cerr<<"processed_seconds="<<e->reader->cursor/16000.<<std::endl;
        }
        if(!e->stopped)return 3;
        const auto ended=std::chrono::steady_clock::now();
        transcript_t* transcript=nullptr;ok(moonshine_transcribe_stream(e->model,e->stream,0,&transcript));
        size_t lines=0;double speech=0;
        if(transcript)for(uint64_t i=0;i<transcript->line_count;++i){auto& line=transcript->lines[i];if(line.is_complete&&line.text&&line.text[0]){++lines;speech+=line.duration;}}
        rusage usage{};getrusage(RUSAGE_SELF,&usage);
        std::cout<<"{\"audio_seconds\":"<<e->reader->cursor/16000.
            <<",\"model_seconds\":"<<std::chrono::duration<double>(loaded-started).count()
            <<",\"open_seconds\":"<<std::chrono::duration<double>(opened-loaded).count()
            <<",\"processing_seconds\":"<<std::chrono::duration<double>(ended-opened).count()
            <<",\"total_seconds\":"<<std::chrono::duration<double>(ended-started).count()
            <<",\"read_seconds\":"<<readMs/1000<<",\"inference_seconds\":"<<inferenceMs/1000
            <<",\"max_step_seconds\":"<<maximumStepMs/1000<<",\"steps\":"<<steps
            <<",\"completed_lines\":"<<lines<<",\"speech_span_seconds\":"<<speech
            <<",\"peak_rss_kib\":"<<usage.ru_maxrss<<",\"eof\":true}"<<std::endl;
    }catch(const std::exception& error){std::cerr<<error.what()<<'\n';return 1;}
}
