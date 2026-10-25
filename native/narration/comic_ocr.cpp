// Conservative on-device v6 Small pipeline. Reuses the narration ORT library;
// no Python, OpenCV, network access or scan-specific annotation at runtime.
#include "comic_ocr.h"
#ifdef _WIN32
#define NOMINMAX
#include <windows.h>
#define ORT_API_MANUAL_INIT
#endif
#include "onnxruntime_cxx_api.h"
#include "ort_environment.h"
#include "json.hpp"
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstring>
#include <fstream>
#include <map>
#include <memory>
#include <mutex>
#include <numeric>
#include <sstream>
#include <stdexcept>
#include <vector>

namespace comic {
using J=nlohmann::json;
using Clock=std::chrono::steady_clock;
double milliseconds(Clock::time_point start){return std::chrono::duration<double,std::milli>(Clock::now()-start).count();}
struct Rect {
    int x0=0,y0=0,x1=0,y1=0;
    int w()const{return x1-x0;} int h()const{return y1-y0;}
    int area()const{return w()*h();}
    double cx()const{return (x0+x1)*.5;} double cy()const{return (y0+y1)*.5;}
    J json()const{return {x0,y0,x1,y1};}
};
int overlap(int a,int b,int c,int d){return std::max(0,std::min(b,d)-std::max(a,c));}
Rect merge(Rect a,Rect b){return {std::min(a.x0,b.x0),std::min(a.y0,b.y0),std::max(a.x1,b.x1),std::max(a.y1,b.y1)};}
struct Component {Rect box;int pixels=0;double score=0;};
struct Components {std::vector<int> labels;std::vector<Component> regions;};
Components components(const std::vector<uint8_t>& mask,int w,int h,const float* probabilities=nullptr){
    Components out;out.labels.resize(mask.size());out.regions.push_back({});std::vector<int> queue;
    for(int at=0;at<w*h;++at){
        if(!mask[at]||out.labels[at])continue;
        const int id=int(out.regions.size());Component c{{at%w,at/w,at%w+1,at/w+1},0,0};
        queue.clear();queue.push_back(at);out.labels[at]=id;
        for(size_t n=0;n<queue.size();++n){
            int p=queue[n],x=p%w,y=p/w;c.box=merge(c.box,{x,y,x+1,y+1});++c.pixels;
            if(probabilities)c.score+=probabilities[p];
            for(int dy=-1;dy<=1;++dy)for(int dx=-1;dx<=1;++dx){
                int xx=x+dx,yy=y+dy;if(xx<0||xx>=w||yy<0||yy>=h)continue;int q=yy*w+xx;
                if(mask[q]&&!out.labels[q]){out.labels[q]=id;queue.push_back(q);}
            }
        }
        if(c.pixels)c.score/=c.pixels;out.regions.push_back(c);
    }
    return out;
}
std::vector<uint32_t> codepoints(const std::string& s){
    std::vector<uint32_t> result;
    for(size_t i=0;i<s.size();){uint32_t c=uint8_t(s[i++]);int n=0;
        if(c>=0xf0){c&=7;n=3;}else if(c>=0xe0){c&=15;n=2;}else if(c>=0xc0){c&=31;n=1;}
        while(n--&&i<s.size())c=(c<<6)|(uint8_t(s[i++])&63);result.push_back(c);}
    return result;
}
bool han(uint32_t c){return c>=0x3400&&c<=0x9fff;}
bool kana(uint32_t c){return c>=0x3040&&c<=0x30ff;}
struct Reading {std::string text;double confidence=0;};
struct Detection {Rect box,core;};
struct Line {Rect box,core;Reading first,second;bool vertical=false,inset_verified=false,crop_recovered=false;int white=0,ruby=-1;};

class Engine {
    narration_ort::Lease environment;
    Ort::SessionOptions options;
    std::unique_ptr<Ort::Session> detector,recognizer;
    Ort::AllocatorWithDefaultOptions allocator;
    std::vector<std::string> alphabet;
    std::atomic<int64_t> epoch{0};
    std::mutex running;
    double load_ms=0;
    // Per-image memoization only: identical pixels, crop and tensor width have
    // identical inference. Distinct verification crops still run independently.
    std::map<std::array<int,5>,Reading> readings;
    int reading_runs=0,reading_hits=0;
    void check(int64_t token){if(epoch.load()!=token)throw std::runtime_error("cancelled");}
    std::unique_ptr<Ort::Session> load(const std::string& path){
#ifdef _WIN32
        std::wstring wide(path.begin(),path.end());return std::make_unique<Ort::Session>(*environment->env,wide.c_str(),options);
#else
        return std::make_unique<Ort::Session>(*environment->env,path.c_str(),options);
#endif
    }
    std::vector<Ort::Value> run(Ort::Session& session,std::vector<float>& data,int h,int w,int batch=1){
        std::array<int64_t,4> shape{batch,3,h,w};
        auto info=Ort::MemoryInfo::CreateCpu(OrtArenaAllocator,OrtMemTypeDefault);
        auto tensor=Ort::Value::CreateTensor<float>(info,data.data(),data.size(),shape.data(),4);
        auto input=session.GetInputNameAllocated(0,allocator),output=session.GetOutputNameAllocated(0,allocator);
        const char* in=input.get();const char* out=output.get();
        return session.Run(Ort::RunOptions{nullptr},&in,&tensor,1,&out,1);
    }
    static float sample(const uint8_t* rgb,int w,int h,double x,double y,int channel){
        x=std::clamp(x,0.,double(w-1));y=std::clamp(y,0.,double(h-1));int x0=int(x),y0=int(y),x1=std::min(x0+1,w-1),y1=std::min(y0+1,h-1);
        double fx=x-x0,fy=y-y0;auto at=[&](int xx,int yy){return rgb[(yy*w+xx)*3+channel];};
        return float((at(x0,y0)*(1-fx)+at(x1,y0)*fx)*(1-fy)+(at(x0,y1)*(1-fx)+at(x1,y1)*fx)*fy);
    }
    std::vector<Detection> detect(const uint8_t* rgb,int w,int h,int64_t token){
        double scale=std::min(1.,1280./std::max(w,h));
        int dw=std::max(32,int(std::round(w*scale/32))*32),dh=std::max(32,int(std::round(h*scale/32))*32);
        std::vector<float> data(size_t(3)*dw*dh);const double mean[]={.485,.456,.406},sd[]={.229,.224,.225};
        for(int c=0;c<3;++c)for(int y=0;y<dh;++y)for(int x=0;x<dw;++x)
            data[(c*dh+y)*dw+x]=float((sample(rgb,w,h,(x+.5)*w/dw-.5,(y+.5)*h/dh-.5,2-c)/255.-mean[c])/sd[c]);
        check(token);auto output=run(*detector,data,dh,dw);check(token);
        auto shape=output[0].GetTensorTypeAndShapeInfo().GetShape();
        if(shape.size()!=4||shape[0]!=1||shape[1]!=1)throw std::runtime_error("detector_shape");
        int mh=int(shape[2]),mw=int(shape[3]);const float* scores=output[0].GetTensorData<float>();
        std::vector<uint8_t> mask(size_t(mw)*mh);for(size_t i=0;i<mask.size();++i)mask[i]=scores[i]>.2f;
        auto cc=components(mask,mw,mh,scores);std::vector<Detection> boxes;
        for(size_t i=1;i<cc.regions.size()&&boxes.size()<300;++i){
            const auto& c=cc.regions[i];Rect b=c.box;
            if(c.pixels<6||std::min(b.w(),b.h())<3||c.score<.45)continue;
            double score=0;for(int y=b.y0;y<b.y1;++y)for(int x=b.x0;x<b.x1;++x)score+=scores[y*mw+x];
            if(score/b.area()<.45)continue;
            double grow=1.4*b.area()/(2.*(b.w()+b.h()));
            Rect r{std::max(0,int(std::floor((b.x0-grow)*w/mw))),std::max(0,int(std::floor((b.y0-grow)*h/mh))),
                   std::min(w,int(std::ceil((b.x1+grow)*w/mw))),std::min(h,int(std::ceil((b.y1+grow)*h/mh)))};
            Rect core{int(std::floor(double(b.x0)*w/mw)),int(std::floor(double(b.y0)*h/mh)),
                      int(std::ceil(double(b.x1)*w/mw)),int(std::ceil(double(b.y1)*h/mh))};
            if(r.w()>4&&r.h()>4)boxes.push_back({r,core});
        }
        std::sort(boxes.begin(),boxes.end(),[](Detection a,Detection b){return a.box.y0==b.box.y0?a.box.x0<b.box.x0:a.box.y0<b.box.y0;});return boxes;
    }
    struct Crop {Rect box;bool rotate;int cw,ch,rw,tw;
        std::array<int,5> key()const{return {box.x0,box.y0,box.x1,box.y1,tw};}
    };
    static Crop cropInfo(int w,int h,Rect box,int padding,int minimum_width=32){
        box={std::max(0,box.x0-padding),std::max(0,box.y0-padding),std::min(w,box.x1+padding),std::min(h,box.y1+padding)};
        bool rotate=box.h()>1.5*box.w();int cw=rotate?box.h():box.w(),ch=rotate?box.w():box.h();
        int rw=std::min(1536,std::max(1,int(std::ceil(48.*cw/ch)))),tw=std::max(minimum_width,((rw+31)/32)*32);
        return {box,rotate,cw,ch,rw,tw};
    }
    static void cropPixels(const uint8_t* rgb,int w,int h,const Crop& crop,float* data){
        const auto& box=crop.box;
        for(int c=0;c<3;++c)for(int y=0;y<48;++y)for(int x=0;x<crop.rw;++x){
            double xx=(x+.5)*crop.cw/crop.rw-.5,yy=(y+.5)*crop.ch/48-.5;
            double sx=crop.rotate?box.x1-1-yy:box.x0+xx,sy=crop.rotate?box.y0+xx:box.y0+yy;
            data[(c*48+y)*crop.tw+x]=sample(rgb,w,h,sx,sy,2-c)/127.5f-1.f;
        }
    }
    Reading decodeReading(const float* values,int steps,int classes){
        int last=-1,count=0;Reading reading;
        for(int t=0;t<steps;++t){const float* row=values+t*classes;int id=int(std::max_element(row,row+classes)-row);
            if(id&&id!=last){reading.text+=alphabet[id];reading.confidence+=row[id];++count;}last=id;}
        if(count)reading.confidence/=count;return reading;
    }
    // Independent first reads share a batch only at identical tensor widths.
    // Do not speculate verification reads for lines that may fail the first gate.
    void primePair(const uint8_t* rgb,int w,int h,Rect first,Rect second,int64_t token){
        const auto a=cropInfo(w,h,first,0),b=cropInfo(w,h,second,0);
        if(a.tw!=b.tw||a.key()==b.key()||readings.count(a.key())||readings.count(b.key()))return;
        const size_t stride=size_t(3)*48*a.tw;
        std::vector<float> data(stride*2,0);
        cropPixels(rgb,w,h,a,data.data());cropPixels(rgb,w,h,b,data.data()+stride);
        check(token);auto output=run(*recognizer,data,48,a.tw,2);check(token);
        auto shape=output[0].GetTensorTypeAndShapeInfo().GetShape();
        if(shape.size()!=3||shape[0]!=2||size_t(shape[2])!=alphabet.size())throw std::runtime_error("recognizer_batch_shape");
        const float* values=output[0].GetTensorData<float>();
        readings.emplace(a.key(),decodeReading(values,int(shape[1]),int(shape[2])));
        readings.emplace(b.key(),decodeReading(values+shape[1]*shape[2],int(shape[1]),int(shape[2])));
        ++reading_runs;
    }
    Reading recognize(const uint8_t* rgb,int w,int h,Rect box,int padding,int64_t token,int minimum_width=32){
        const auto crop=cropInfo(w,h,box,padding,minimum_width);
        check(token);
        const auto key=crop.key();
        auto cached=readings.find(key);
        if(cached!=readings.end()){++reading_hits;return cached->second;}
        ++reading_runs;
        std::vector<float> data(size_t(3)*48*crop.tw,0);
        cropPixels(rgb,w,h,crop,data.data());
        check(token);auto output=run(*recognizer,data,48,crop.tw);check(token);
        auto shape=output[0].GetTensorTypeAndShapeInfo().GetShape();
        if(shape.size()!=3||shape[0]!=1||size_t(shape[2])!=alphabet.size())throw std::runtime_error("recognizer_shape");
        auto reading=decodeReading(output[0].GetTensorData<float>(),int(shape[1]),int(shape[2]));
        readings.emplace(key,reading);return reading;
    }
public:
    explicit Engine(const std::string& root){
        auto started=Clock::now();
        options.SetIntraOpNumThreads(2);options.SetInterOpNumThreads(1);options.DisableCpuMemArena();
        options.AddConfigEntry("session.intra_op.allow_spinning","0");options.AddConfigEntry("session.inter_op.allow_spinning","0");
        detector=load(root+"/multi_PP-OCRv6_det_small.onnx");recognizer=load(root+"/multi_PP-OCRv6_rec_small.onnx");
        auto metadata=recognizer->GetModelMetadata();auto chars=metadata.LookupCustomMetadataMapAllocated("character",allocator);
        if(!chars)throw std::runtime_error("missing_alphabet");
        alphabet.push_back("");std::istringstream input(chars.get());std::string line;
        while(std::getline(input,line)){if(!line.empty()&&line.back()=='\r')line.pop_back();alphabet.push_back(line);}
        alphabet.push_back(" ");
        load_ms=milliseconds(started);
    }
    void cancel(int64_t token){epoch.store(token);}
    J analyze(const uint8_t* rgb,int w,int h,int64_t token,bool unrestricted=false){
        std::lock_guard<std::mutex> lock(running);check(token);
        readings.clear();reading_runs=0;reading_hits=0;
        auto started=Clock::now();
        if(!rgb||w<16||h<16||w>1600||h>1600)throw std::runtime_error("page_size");
        std::vector<uint8_t> white(size_t(w)*h);
        for(size_t i=0;i<white.size();++i)white[i]=(.299*rgb[i*3]+.587*rgb[i*3+1]+.114*rgb[i*3+2])>210;
        // Scanned outlines often have one-pixel gaps. Break narrow white bridges
        // before labeling, otherwise outside paper joins the balloon and its
        // curved border is mistaken for an undetected text column. A 3x3 opening
        // only removes white pixels; it never paints over or invents text ink.
        std::vector<uint8_t> interior(white.size()),opened(white.size());
        for(int y=1;y<h-1;++y)for(int x=1;x<w-1;++x){
            bool all=true;for(int dy=-1;dy<=1&&all;++dy)for(int dx=-1;dx<=1;++dx)if(!white[(y+dy)*w+x+dx]){all=false;break;}
            interior[y*w+x]=all;
        }
        for(int y=0;y<h;++y)for(int x=0;x<w;++x){
            bool any=false;for(int dy=-1;dy<=1&&!any;++dy)for(int dx=-1;dx<=1;++dx){
                int xx=x+dx,yy=y+dy;if(xx>=0&&xx<w&&yy>=0&&yy<h&&interior[yy*w+xx]){any=true;break;}}
            opened[y*w+x]=any;
        }
        auto whites=components(white,w,h);check(token);double white_ms=milliseconds(started);auto stage=Clock::now();
        auto boxes=detect(rgb,w,h,token);double detect_ms=milliseconds(stage);stage=Clock::now();
        {
            auto separated=components(opened,w,h);
            std::vector<int> owner(separated.regions.size()),best(whites.regions.size());
            for(size_t p=0;p<white.size();++p)if(separated.labels[p])owner[separated.labels[p]]=whites.labels[p];
            for(size_t i=1;i<separated.regions.size();++i){int original=owner[i];
                if(original&&separated.regions[i].pixels>separated.regions[best[original]].pixels)best[original]=int(i);}
            // Never split a detected column or discard another detected line
            // from the same region. Dense Japanese print can connect through
            // narrow spaces; keep its original region when opening cuts text.
            for(const auto& detection:boxes){Rect b=detection.core;std::map<int,int> votes;
                for(int y=b.y0;y<b.y1;++y)for(int x=b.x0;x<b.x1;++x)if(whites.labels[y*w+x])++votes[whites.labels[y*w+x]];
                int original=0,most=0;for(auto v:votes)if(v.second>most){most=v.second;original=v.first;}
                if(!original||!best[original])continue;
                Rect r=separated.regions[best[original]].box;
                double containment=double(overlap(b.x0,b.x1,r.x0,r.x1))*overlap(b.y0,b.y1,r.y0,r.y1)/b.area();
                if(containment<.98)best[original]=0;
            }
            for(size_t i=1;i<best.size();++i)if(best[i]){
                if(separated.regions[best[i]].box.area()>=whites.regions[i].box.area()*.99)best[i]=0;
                else whites.regions[i]=separated.regions[best[i]];
            }
            for(size_t p=0;p<white.size();++p){int id=whites.labels[p];if(id&&best[id]&&separated.labels[p]!=best[id])whites.labels[p]=0;}
        }
        white_ms+=milliseconds(stage);stage=Clock::now();std::vector<Line> lines,candidates;
        int filtered_regions=0;
        for(const auto& detection:boxes){
            Rect box=detection.box;
            Line line;line.box=box;line.core=detection.core;line.vertical=box.h()>1.35*box.w();
            std::map<int,int> votes;
            for(int y=box.y0;y<box.y1;++y)for(int x=box.x0;x<box.x1;++x)if(whites.labels[y*w+x])++votes[whites.labels[y*w+x]];
            int most=0;for(auto v:votes)if(v.second>most){most=v.second;line.white=v.first;}
            if(most<box.area()*.25)line.white=0;
            const auto& region=whites.regions[line.white];const auto& bounds=region.box;
            // These regions cannot pass the bubble gate at any confidence. Avoid
            // spending two neural runs on page furniture or open page backgrounds.
            if(!unrestricted&&(!line.white||bounds.x0==0||bounds.y0==0||bounds.x1==w||bounds.y1==h||region.pixels>=w*h*.15)){++filtered_regions;continue;}
            candidates.push_back(line);
        }
        std::map<int,std::vector<Rect>> batches;
        for(const auto& line:candidates)batches[cropInfo(w,h,line.box,0).tw].push_back(line.box);
        for(const auto& batch:batches)for(size_t i=1;i<batch.second.size();i+=2)
            primePair(rgb,w,h,batch.second[i-1],batch.second[i],token);
        for(auto line:candidates){
            Rect box=line.box;const auto& region=whites.regions[line.white];const auto& bounds=region.box;
            line.first=recognize(rgb,w,h,box,0,token);
            if(line.first.text.empty()||line.first.confidence<.5)continue;
            const bool compact=region.pixels<box.area()*12.&&region.pixels>bounds.area()*.4;
            if(line.first.confidence>=.94||(!line.vertical&&compact&&line.first.confidence>=.85))line.second=recognize(rgb,w,h,box,2,token);
            if(!line.vertical&&compact&&line.first.confidence>=.85&&box.w()>10&&box.h()>10
               &&(line.first.text!=line.second.text||std::min(line.first.confidence,line.second.confidence)<.96)){
                auto inset=recognize(rgb,w,h,box,-2,token);
                if(inset.confidence>=.96){
                    if(inset.text==line.first.text&&line.first.confidence>=.96){line.second=inset;line.inset_verified=true;}
                    else if(inset.text==line.second.text&&line.second.confidence>=.96){line.first=inset;line.inset_verified=true;}
                }
            }
            // Keep the established 320px context as a bounded fallback for a
            // short line whose two narrow reads agree but one is borderline.
            // Admission still needs two independent >=.96 agreeing readings.
            if(compact&&line.first.text==line.second.text&&std::min(line.first.confidence,line.second.confidence)<.96
               &&std::max(line.first.confidence,line.second.confidence)>=.96){
                bool first_weaker=line.first.confidence<line.second.confidence;
                auto padded=recognize(rgb,w,h,box,first_weaker?0:2,token,320);
                if(padded.confidence>=.96&&padded.text==line.first.text){
                    if(first_weaker)line.first=padded;else line.second=padded;
                }
            }
            // Detector expansion may include ink from the next parallel column.
            // Keep the original detection for completeness checks, but separate
            // recognition crops at the midpoint and vary only their short axis:
            // extending both axes often picks up a neighboring punctuation mark.
            if(line.first.confidence>=.8&&(line.first.text!=line.second.text||std::min(line.first.confidence,line.second.confidence)<.96)){
                Rect separated=box;
                for(const auto& neighbour_detection:boxes){
                    Rect other=neighbour_detection.box;
                    bool orientation=other.h()>1.35*other.w();
                    if(orientation!=line.vertical)continue;
                    double a=line.vertical?box.w():box.h(),b=line.vertical?other.w():other.h();
                    if(std::min(a,b)/std::max(a,b)<.6)continue;
                    int shared=line.vertical?overlap(box.y0,box.y1,other.y0,other.y1):overlap(box.x0,box.x1,other.x0,other.x1);
                    if(shared<.4*(line.vertical?std::min(box.h(),other.h()):std::min(box.w(),other.w())))continue;
                    double centre=line.vertical?box.cx():box.cy(),neighbour=line.vertical?other.cx():other.cy();
                    if(std::abs(centre-neighbour)<.5*std::min(a,b))continue;
                    int middle=int(std::round((centre+neighbour)*.5));
                    if(line.vertical){if(neighbour<centre)separated.x0=std::max(separated.x0,middle);else separated.x1=std::min(separated.x1,middle);}
                    else {if(neighbour<centre)separated.y0=std::max(separated.y0,middle);else separated.y1=std::min(separated.y1,middle);}
                }
                std::vector<Reading> stable;
                bool conflict=false;
                for(int inset:{0,2,4}){
                    Rect crop=separated;
                    if(line.vertical){crop.x0+=inset;crop.x1-=inset;}else {crop.y0+=inset;crop.y1-=inset;}
                    if(std::min(crop.w(),crop.h())<8)continue;
                    auto reading=recognize(rgb,w,h,crop,0,token);
                    if(reading.confidence<.96)continue;
                    if(!stable.empty()&&stable[0].text!=reading.text)conflict=true;
                    stable.push_back(reading);
                }
                // Upright two-digit runs within vertical Japanese text need a
                // separate verification path: rotated crops can confidently omit
                // a narrow digit. Never recover those through crop consensus alone.
                auto has_digits=[](const Reading& reading){auto chars=codepoints(reading.text);
                    return std::any_of(chars.begin(),chars.end(),[](uint32_t c){return (c>='0'&&c<='9')||(c>=0xff10&&c<=0xff19);});};
                bool embedded_digits=line.vertical&&(has_digits(line.first)||has_digits(line.second)
                    ||std::any_of(stable.begin(),stable.end(),has_digits));
                if(stable.size()>=2&&!conflict&&!embedded_digits){line.first=stable[0];line.second=stable[1];line.crop_recovered=true;}
            }
            lines.push_back(line);
        }
        double recognize_ms=milliseconds(stage);stage=Clock::now();
        // Separate small kana along the right side of a Han column are ruby;
        // never remove repeated substrings from recognized dialogue.
        for(size_t i=0;i<lines.size();++i){auto& a=lines[i];auto chars=codepoints(a.first.text);
            if(chars.empty()||a.first.confidence<.9||!std::all_of(chars.begin(),chars.end(),kana))continue;
            std::vector<int> parents;
            for(size_t j=0;j<lines.size();++j){auto& b=lines[j];auto text=codepoints(b.first.text);
                double ratio=a.vertical?double(a.box.w())/b.box.w():double(a.box.h())/b.box.h();
                bool beside=a.vertical?a.box.h()<.6*b.box.h()&&a.box.cx()>b.box.cx()+.2*b.box.w()&&a.box.cx()<b.box.x1+.6*b.box.w()
                    &&overlap(a.box.y0,a.box.y1,b.box.y0,b.box.y1)>.85*a.box.h()
                    :a.box.w()<.6*b.box.w()&&a.box.cy()<b.box.cy()-.2*b.box.h()&&a.box.cy()>b.box.y0-.6*b.box.h()
                    &&overlap(a.box.x0,a.box.x1,b.box.x0,b.box.x1)>.85*a.box.w();
                if(i!=j&&a.vertical==b.vertical&&a.white&&a.white==b.white&&std::any_of(text.begin(),text.end(),han)
                   &&ratio>=.25&&ratio<=.58&&beside)parents.push_back(int(j));
            }
            if(parents.size()==1)a.ruby=parents[0];
        }
        std::vector<int> parent(lines.size());std::iota(parent.begin(),parent.end(),0);
        auto find=[&](int i){while(parent[i]!=i){parent[i]=parent[parent[i]];i=parent[i];}return i;};
        for(size_t i=0;i<lines.size();++i)for(size_t j=0;j<i;++j){
            auto&a=lines[i];auto&b=lines[j];Rect r=a.box,s=b.box;
            if(a.ruby>=0||b.ruby>=0||a.vertical!=b.vertical||!a.white||a.white!=b.white)continue;
            double fa=a.vertical?r.w():r.h(),fb=b.vertical?s.w():s.h(),font=(fa+fb)/2;
            if(std::min(fa,fb)/std::max(fa,fb)<(a.vertical?.6:.45))continue;
            bool adjacent=a.vertical?std::abs(r.cx()-s.cx())<1.65*font&&overlap(r.y0,r.y1,s.y0,s.y1)>.38*std::min(r.h(),s.h())
                                    :std::abs(r.cy()-s.cy())<1.65*font&&overlap(r.x0,r.x1,s.x0,s.x1)>.38*std::min(r.w(),s.w());
            bool fragment=a.vertical?std::abs(r.cx()-s.cx())<.28*font&&std::max(r.y0,s.y0)-std::min(r.y1,s.y1)<.7*font
                                    :std::abs(r.cy()-s.cy())<.28*font&&std::max(r.x0,s.x0)-std::min(r.x1,s.x1)<.7*font;
            if(adjacent||fragment)parent[find(int(i))]=find(int(j));
        }
        std::map<int,std::vector<int>> groups;for(size_t i=0;i<lines.size();++i)if(lines[i].ruby<0)groups[find(int(i))].push_back(int(i));
        bool japanese=false;
        for(const auto& line:lines){auto chars=codepoints(line.first.text);if(line.first.confidence>=.94&&std::count_if(chars.begin(),chars.end(),kana)>=2)japanese=true;}
        J blocks=J::array(),raw=J::array();int accepted=0;
        for(size_t i=0;i<lines.size();++i){auto&l=lines[i];raw.push_back({{"id",i},{"rect",l.box.json()},{"core_rect",l.core.json()},{"text",l.first.text},
            {"score",l.first.confidence},{"verification_text",l.second.text},{"verification_score",l.second.confidence},{"ruby_parent",l.ruby},
            {"white_region",l.white},{"white_rect",whites.regions[l.white].box.json()},{"inset_verified",l.inset_verified},{"crop_recovered",l.crop_recovered}});}
        for(auto& group:groups){auto ids=group.second;bool vertical=lines[ids[0]].vertical;
            // Stable columns/rows: compare against a fixed anchor, never a pairwise fuzzy comparator.
            std::sort(ids.begin(),ids.end(),[&](int i,int j){auto a=lines[i].box,b=lines[j].box;
                double x=vertical?a.cx():a.cy(),y=vertical?b.cx():b.cy();return x==y?i<j:(vertical?x>y:x<y);});
            std::vector<int> ordered;
            for(size_t at=0;at<ids.size();){size_t end=at+1;Rect anchor=lines[ids[at]].box;
                while(end<ids.size()){Rect b=lines[ids[end]].box;
                    if((vertical?std::abs(anchor.cx()-b.cx()):std::abs(anchor.cy()-b.cy()))>=.35*(vertical?std::min(anchor.w(),b.w()):std::min(anchor.h(),b.h())))break;
                    ++end;}
                std::sort(ids.begin()+at,ids.begin()+end,[&](int i,int j){Rect a=lines[i].box,b=lines[j].box;
                    int x=vertical?a.y0:a.x0,y=vertical?b.y0:b.x0;return x==y?i<j:x<y;});
                ordered.insert(ordered.end(),ids.begin()+at,ids.begin()+end);at=end;}
            ids=std::move(ordered);
            Rect box=lines[ids[0]].box,core=lines[ids[0]].core;std::string text;double confidence=1;bool agreement=true;
            for(int id:ids){auto&l=lines[id];box=merge(box,l.box);core=merge(core,l.core);
                // Preserve word boundaries in horizontal Latin dialogue when merging OCR rows.
                auto latin=[](unsigned char c){return (c>='A'&&c<='Z')||(c>='a'&&c<='z');};
                if(!vertical&&!text.empty()&&!l.first.text.empty()&&latin(static_cast<unsigned char>(l.first.text.front()))
                   &&static_cast<unsigned char>(text.back())<128){if(text.back()=='-')text.pop_back();else text+=' ';}
                text+=l.first.text;confidence=std::min(confidence,std::min(l.first.confidence,l.second.confidence));
                agreement=agreement&&l.first.text==l.second.text;}
            J reasons=J::array();if(!agreement)reasons.push_back("recognition_disagrees");if(confidence<.96)reasons.push_back("low_confidence");
            auto chars=codepoints(text);int cjk=0;for(auto c:chars)if(han(c)||kana(c))++cjk;
            if(cjk<3||chars.size()>120)reasons.push_back("unsupported_text");
            const int region=lines[ids[0]].white;Rect hit=box;bool enclosure=false;J rows=J::array();
            if(region){auto&c=whites.regions[region];Rect b=c.box;
                // Bold horizontal handwriting fills much more of the bubble than
                // thin vertical print. Still require an enclosed, unique region,
                // complete text containment and a nonrectangular speech contour.
                double containment=double(overlap(box.x0,box.x1,b.x0,b.x1))*overlap(box.y0,box.y1,b.y0,b.y1)/box.area();
                enclosure=c.pixels>box.area()*(vertical?1.15:.4)&&b.area()>box.area()*1.05&&containment>=.9
                    &&c.pixels<std::min(box.area()*12.,w*h*.15)
                    &&b.x0>0&&b.y0>0&&b.x1<w&&b.y1<h&&c.pixels>b.area()*(vertical?.5:.4)&&c.pixels<b.area()*.94;
                // Detection unclip adds recognition context, not printed text.
                // Tight balloons may contain every glyph even when
                // that expanded crop crosses their border. Verify the original
                // detector support instead, with stricter containment; retain
                // the same unique enclosure and missing-ink checks below.
                double core_containment=double(overlap(core.x0,core.x1,b.x0,b.x1))*overlap(core.y0,core.y1,b.y0,b.y1)/core.area();
                if(!enclosure)enclosure=core_containment>=.98&&b.area()>core.area()*1.3
                    &&c.pixels>core.area()*(vertical?1.15:.8)&&c.pixels<std::min(core.area()*12.,w*h*.15)
                    &&b.x0>0&&b.y0>0&&b.x1<w&&b.y1<h&&c.pixels>b.area()*(vertical?.5:.4)&&c.pixels<b.area()*.94;
                // A connected white background shared by separate text groups
                // is not a uniquely selectable speech bubble.
                for(size_t k=0;k<lines.size();++k)if(lines[k].ruby<0&&lines[k].white==region&&find(int(k))!=find(ids[0]))enclosure=false;
                if(enclosure){hit=b;
                    int full_rows=0;
                    for(int y=b.y0;y<b.y1;++y){int left=w,right=0;
                        for(int x=b.x0;x<b.x1;++x)if(whites.labels[y*w+x]==region){left=std::min(left,x);right=std::max(right,x+1);}
                        if(right-left>=b.w()*.95)++full_rows;
                        rows.push_back({left,right});}
                    if(!vertical&&full_rows>b.h()*.8)reasons.push_back("rectangular_heading");
                }
            }
            if(!enclosure)reasons.push_back("uncertain_bubble");
            // High recognizer confidence cannot detect a missed column. Reject
            // substantial interior ink that no detector box (including ruby) covers.
            if(enclosure){
                std::vector<uint8_t> unexplained(size_t(hit.w())*hit.h());
                for(int y=hit.y0;y<hit.y1;++y){int left=rows[y-hit.y0][0],right=rows[y-hit.y0][1];
                    for(int x=left+3;x<right-3;++x){
                        if(y<hit.y0+3||y>=hit.y1-3)continue;
                        // Test distance from the curved silhouette, not only
                        // from its bounding rectangle. Ink along a sloped edge
                        // is the outline; missing glyphs in the interior remain.
                        bool inside=true;
                        for(int dy=-3;dy<=3;++dy){int lo=rows[y-hit.y0+dy][0],hi=rows[y-hit.y0+dy][1];
                            if(x<lo+3||x>=hi-3){inside=false;break;}}
                        if(!inside)continue;
                        size_t pixel=size_t(y*w+x)*3;
                        if(.299*rgb[pixel]+.587*rgb[pixel+1]+.114*rgb[pixel+2]>120)continue;
                        bool covered=false;
                        for(const auto& l:lines){Rect b=l.box;if(x>=b.x0-2&&x<b.x1+2&&y>=b.y0-2&&y<b.y1+2){covered=true;break;}}
                        if(!covered)unexplained[(y-hit.y0)*hit.w()+x-hit.x0]=1;
                    }
                }
                auto ink=components(unexplained,hit.w(),hit.h());double font=vertical?lines[ids[0]].box.w():lines[ids[0]].box.h();
                for(size_t i=1;i<ink.regions.size();++i){const auto& c=ink.regions[i];
                    if(c.pixels>=std::max(8.,font*font*.02)&&c.box.w()>=font*.2&&c.box.h()>=font*.2){reasons.push_back("unrecognized_ink");break;}}
            }
            const bool verified=reasons.empty();
            const bool eligible=verified||(unrestricted&&!chars.empty()&&chars.size()<=1000);
            // Unverified candidates use their own text rectangle, never an open/shared background.
            if(!verified&&unrestricted){hit=box;rows=J::array();}
            if(eligible)++accepted;
            blocks.push_back({{"id",blocks.size()},{"rect",box.json()},{"hit_rect",hit.json()},{"hit_rows",rows},
                {"text",text},{"score",confidence},{"line_ids",ids},{"eligible",eligible},{"verified",verified},{"skip_reasons",reasons},
                {"language",cjk==0?"en":japanese?"ja":"zh"},{"direction",vertical?"vertical_rtl":"horizontal_ltr"}});
        }
        return {{"schema_version",3},{"profile",unrestricted?"v6_small_debug_unrestricted":"v6_small_conservative_v3"},{"page_size",{w,h}},{"blocks",blocks},
            {"lines",raw},{"eligible_count",accepted},{"detected_count",lines.size()},{"filtered_open_regions",filtered_regions},{"state","ready"},
            {"recognition_runs",reading_runs},{"recognition_cache_hits",reading_hits},
            {"timings_ms",{{"model_load",load_ms},{"white_regions",white_ms},{"detection",detect_ms},{"recognition",recognize_ms},{"layout",milliseconds(stage)},{"total",milliseconds(started)}}}};
    }
};
std::mutex registry_mutex;std::map<int64_t,std::shared_ptr<Engine>> registry;std::atomic<int64_t> serial{0};
std::shared_ptr<Engine> lookup(int64_t id){std::lock_guard<std::mutex> guard(registry_mutex);auto it=registry.find(id);if(it==registry.end())throw std::runtime_error("closed");return it->second;}
const char* json_text(const J& j){auto text=j.dump();auto p=new char[text.size()+1];std::memcpy(p,text.c_str(),text.size()+1);return p;}
}
extern "C" int64_t comic_create(const char* directory){
    try{
#ifdef _WIN32
        static std::once_flag once;std::call_once(once,[]{auto dll=LoadLibraryW(L"onnxruntime.dll");if(!dll)throw std::runtime_error("ort_unavailable");
            auto get=reinterpret_cast<const OrtApiBase*(ORT_API_CALL*)()>(GetProcAddress(dll,"OrtGetApiBase"));
            if(!get)throw std::runtime_error("ort_api");Ort::InitApi(get()->GetApi(ORT_API_VERSION));});
#endif
        auto engine=std::make_shared<comic::Engine>(directory);int64_t id=++comic::serial;
        std::lock_guard<std::mutex> guard(comic::registry_mutex);comic::registry[id]=engine;return id;
    }catch(...){return 0;}
}
extern "C" void comic_cancel(int64_t handle,int64_t generation){try{comic::lookup(handle)->cancel(generation);}catch(...){}}
extern "C" const char* comic_analyze(int64_t handle,const uint8_t* rgb,int width,int height,int64_t generation){
    try{return comic::json_text(comic::lookup(handle)->analyze(rgb,width,height,generation));}
    catch(const std::exception& e){return comic::json_text({{"state","error"},{"error",e.what()}});}
}
extern "C" void comic_destroy(int64_t handle){std::lock_guard<std::mutex> guard(comic::registry_mutex);comic::registry.erase(handle);}
extern "C" const char* comic_analyze_unrestricted(int64_t handle,const uint8_t* rgb,int width,int height,int64_t generation){
    try{return comic::json_text(comic::lookup(handle)->analyze(rgb,width,height,generation,true));}
    catch(const std::exception& e){return comic::json_text({{"state","error"},{"error",e.what()}});}
}
extern "C" void comic_free(const char* text){delete[] text;}
