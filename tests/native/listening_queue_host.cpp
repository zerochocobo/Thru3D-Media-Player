// Exercise the production stream's finalized watermark, cancellation and bounded
// restart used by the queue. No subtitle strings or media paths are reported.
#include "../../native/narration/listening_jni.cpp"
#include <iostream>
#include <sys/resource.h>
static double number(const std::string& json,const char* key){auto at=json.find(key);if(at==std::string::npos)throw std::runtime_error("missing_metric");return std::stod(json.substr(at+std::char_traits<char>::length(key)));}
int main(int argc,char** argv){
    if(argc!=5)return 2;
    try{
        auto began=std::chrono::steady_clock::now();auto e=std::make_shared<Engine>();
        e->model=listeningLoadModel(argv[1],argv[2]);ok(e->model);
        double covered=0,readerFrom=-1000,through=0;int opens=0,steps=0,emitted=0;bool cancelTested=false;
        auto reopen=[&]{
            e->reader.reset();if(e->stream>=0)moonshine_free_stream(e->model,e->stream);e->stream=-1;
            e->cancelled=false;readerFrom=std::max(0.0,covered-8);through=readerFrom;
            e->reader=std::make_unique<AudioReader>(&e->cancelled);e->reader->open(argv[3],"",std::stoi(argv[4]),readerFrom,false,-1);
            e->offset=readerFrom;e->stream=moonshine_create_stream(e->model,0);ok(e->stream);ok(moonshine_start_stream(e->model,e->stream));e->stopped=false;e->emitted=0;++opens;
        };
        reopen();
        while(!e->stopped&&steps++<10000){
            if(through-readerFrom>=300)reopen();
            const auto prior=e->emitted;auto json=listening_step(e);
            emitted+=int(e->emitted-prior);
            const double end=number(json,"\"through\":");const double settled=number(json,"\"settled\":");
            if(end<through||end>through+1.01||settled>end)throw std::runtime_error("invalid_watermark");
            through=end;covered=std::max(covered,settled);
            if(!cancelTested&&through>=125){
                e->cancelled=true;bool rejected=false;try{listening_step(e);}catch(const std::exception&){rejected=true;}
                if(!rejected)throw std::runtime_error("cancel_not_observed");cancelTested=true;reopen();
            }
        }
        if(!e->stopped||!cancelTested||opens<3||covered<599.9||emitted==0)throw std::runtime_error("incomplete_queue_run");
        rusage usage{};getrusage(RUSAGE_SELF,&usage);
        std::cout<<"{\"covered_seconds\":"<<covered<<",\"opens\":"<<opens<<",\"steps\":"<<steps<<",\"finalized_updates\":"<<emitted
            <<",\"cancel_resume\":true,\"eof\":true,\"total_seconds\":"<<std::chrono::duration<double>(std::chrono::steady_clock::now()-began).count()<<",\"peak_rss_kib\":"<<usage.ru_maxrss<<"}\n";
    }catch(const std::exception& error){std::cerr<<error.what()<<'\n';return 1;}
}
