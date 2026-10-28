// Long silence between speech: every step's clock and cue timing, no text.
// Desktop regression for the production reader and step; not a headset claim.
#include "../../native/narration/listening_jni.cpp"
#include <iostream>
int main(int argc,char** argv){
    if(argc!=5)return 2;
    try{
        auto e=std::make_shared<Engine>();
        e->model=listeningLoadModel(argv[1],argv[2]);ok(e->model);
        e->reader=std::make_unique<AudioReader>(&e->cancelled);
        e->offset=std::stod(argv[4]);e->reader->open(argv[3],"",0,e->offset,false,-1);
        e->stream=moonshine_create_stream(e->model,0);ok(e->stream);ok(moonshine_start_stream(e->model,e->stream));
        for(int i=0;!e->stopped&&i<3600;++i){
            auto result=listening_step(e);
            // Drop recognized text; keep the clock and cue boundaries.
            std::string clean;bool quoted=false;
            for(size_t j=0;j<result.size();++j){
                if(result.compare(j,8,"\"text\":\"")==0){clean+="\"text\":\"\"";j+=7;quoted=true;continue;}
                if(quoted){if(result[j]=='\\'){++j;continue;}if(result[j]=='"')quoted=false;continue;}
                clean+=result[j];
            }
            std::cout<<"{\"emitted\":"<<e->emitted<<",\"step\":"<<clean<<"}"<<std::endl;
        }
        return e->stopped?0:3;
    }catch(const std::exception& error){std::cerr<<error.what()<<'\n';return 1;}
}
