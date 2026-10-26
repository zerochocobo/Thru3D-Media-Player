// Same production audio reader, step logic, models and C ABI on desktop Linux.
// Does not establish Android/headset throughput.
#include "../../native/narration/listening_jni.cpp"
#include <iostream>
int main(int argc,char** argv){
    if(argc!=6&&argc!=7)return 2;
    try{
        auto e=std::make_shared<Engine>();std::string language=argv[2];
        e->model=listeningLoadModel(argv[1],language,argc==7?argv[6]:"0.65");ok(e->model);
        e->reader=std::make_unique<AudioReader>(&e->cancelled);
        e->offset=std::stod(argv[5]);e->reader->open(argv[3],"",std::stoi(argv[4]),e->offset,false,-1);
        e->stream=moonshine_create_stream(e->model,0);ok(e->stream);ok(moonshine_start_stream(e->model,e->stream));
        for(int i=0;!e->stopped&&i<180;++i)std::cout<<listening_step(e)<<std::endl;
        if(!e->stopped)return 3;
        e->cancelled=true;bool cancelled=false;try{listening_step(e);}catch(const std::exception&){cancelled=true;}
        return cancelled?0:4;
    }catch(const std::exception& error){std::cerr<<error.what()<<'\n';return 1;}
}
