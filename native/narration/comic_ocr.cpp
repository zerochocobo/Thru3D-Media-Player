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
#include "comic_regions.h"
#include "comic_text.h"
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
struct Detection {Rect box,core;int orientation=0;bool recovered=false;};
struct Line {Rect box,core;Reading first,second;std::vector<std::array<int,6>> speech_crops;std::string speech_anchor_text;double speech_anchor_punctuation=0;bool vertical=false,inset_verified=false,crop_recovered=false,region_recovered=false,binary_verified=false,speech_verified=false,region_context=false,axis_context=false,punctuation_recovered=false,speech_anchor_cjk=false;int white=0,ruby=-1;};

// Keep the proven fine-scale hypothesis alongside recovered pockets. A dense
// text column must not lose its original white support merely because another
// scale produces a tighter silhouette.
void fineScalePockets(Components& whites,const std::vector<uint8_t>& white,int w,int h,const std::vector<Rect>& seeds){
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
            auto separated=components(opened,w,h);
            std::vector<int> owner(separated.regions.size()),best(whites.regions.size());
            for(size_t p=0;p<white.size();++p)if(separated.labels[p])owner[separated.labels[p]]=whites.labels[p];
            for(size_t i=1;i<separated.regions.size();++i){int original=owner[i];
                if(original&&separated.regions[i].pixels>separated.regions[best[original]].pixels)best[original]=int(i);}
            // Never split a detected column or discard another detected line
            // from the same region. Dense Japanese print can connect through
            // narrow spaces; keep its original region when opening cuts text.
            for(Rect b:seeds){std::map<int,int> votes;
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
    std::map<std::array<int,6>,Reading> readings;
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
    // Text-guided connected-component recovery: the full-page detector can lose
    // a short column while downscaling. Recover unexplained glyphs in the same
    // contour at the measured print size; recognition still uses original pixels.
    int refineBubbles(const uint8_t* rgb,int w,int h,const Components& whites,std::vector<Detection>& boxes,int64_t token){
        int passes=0;
        for(size_t id=1;id<whites.regions.size()&&passes<32;++id){
            check(token);const auto& c=whites.regions[id];Rect b=c.box;
            if(!bounded(c,w,h)||c.pixels<160||std::min(b.w(),b.h())<18||c.pixels<b.area()*.4)continue;
            bool seeded=false,vertical=true;double font=0;
            for(const auto& d:boxes)if(intersection(d.core,b)>.8*d.core.area()){
                int support=0;for(int y=d.core.y0;y<d.core.y1;++y)for(int x=d.core.x0;x<d.core.x1;++x)if(whites.labels[y*w+x]==int(id))++support;
                if(support<d.core.area()*.2)continue;
                seeded=true;vertical=d.core.h()>1.35*d.core.w();font=std::max(font,double(vertical?d.core.w():d.core.h()));
            }
            if(!seeded||font<6)continue;
            std::vector<std::pair<int,int>> rows(b.h(),{w,0});
            for(int y=b.y0;y<b.y1;++y)for(int x=b.x0;x<b.x1;++x)if(whites.labels[y*w+x]==int(id)){
                auto& row=rows[y-b.y0];row.first=std::min(row.first,x);row.second=std::max(row.second,x+1);
            }
            std::vector<uint8_t> ink(size_t(b.area()));
            for(int y=b.y0+3;y<b.y1-3;++y)for(int x=rows[y-b.y0].first+3;x<rows[y-b.y0].second-3;++x){
                bool inside=true;for(int dy=-3;dy<=3;++dy){auto row=rows[y-b.y0+dy];if(x<row.first+3||x>=row.second-3){inside=false;break;}}
                if(inside){size_t p=size_t(y*w+x)*3;ink[(y-b.y0)*b.w()+x-b.x0]=.299*rgb[p]+.587*rgb[p+1]+.114*rgb[p+2]<120;}
            }
            auto glyphs=components(ink,b.w(),b.h());int letters=0,missing=0;
            std::vector<Rect> missing_glyphs;
            for(size_t k=1;k<glyphs.regions.size();++k){auto g=glyphs.regions[k];Rect r=g.box;
                if(g.pixels<8||std::min(r.w(),r.h())<3||r.w()>.75*b.w()||r.h()>.75*b.h())continue;
                ++letters;r={r.x0+b.x0,r.y0+b.y0,r.x1+b.x0,r.y1+b.y0};bool covered=false;
                for(const auto& d:boxes)if(intersection(r,d.box)>.8*r.area()){covered=true;break;}
                if(!covered){++missing;missing_glyphs.push_back(r);}
            }
            if(!missing||letters<(seeded?1:2))continue;
            if(missing_glyphs.size()<=64){
                ++passes;
                // Connected-component line recovery at the measured print
                // size. Recognition always reads the unmodified page pixels.
                std::vector<Rect> clusters;
                for(auto r:missing_glyphs){
                    if(std::max(r.w(),r.h())<=font*2.5)clusters.push_back(r);
                }
                bool changed=true;
                while(changed){changed=false;
                    for(size_t i=0;i<clusters.size()&&!changed;++i)for(size_t j=0;j<i;++j){auto a=clusters[i],z=clusters[j];
                        double across=vertical?std::abs(a.cx()-z.cx()):std::abs(a.cy()-z.cy());
                        int gap=vertical?std::max(a.y0,z.y0)-std::min(a.y1,z.y1):std::max(a.x0,z.x0)-std::min(a.x1,z.x1);
                        if(across<font*.5&&gap<font*.8){clusters[j]=merge(a,z);clusters.erase(clusters.begin()+i);changed=true;break;}
                    }
                }
                for(auto core:clusters){
                    if(core.w()<font*.25||core.h()<font*.25)continue;
                    int pad=std::max(2,int(font*.18));Rect expanded{std::max(b.x0,core.x0-pad),std::max(b.y0,core.y0-pad),std::min(b.x1,core.x1+pad),std::min(b.y1,core.y1+pad)};
                    bool covered=false;for(const auto& d:boxes)if(intersection(d.core,core)>.3*core.area()){covered=true;break;}
                    if(!covered&&boxes.size()<300)boxes.push_back({expanded,core,vertical?1:2,true});
                }
                continue;
            }

        }
        std::sort(boxes.begin(),boxes.end(),[](Detection a,Detection b){return a.box.y0==b.box.y0?a.box.x0<b.box.x0:a.box.y0<b.box.y0;});
        return passes;
    }

    int localDetections(const uint8_t* rgb,int w,int h,int64_t token,const J& original,std::vector<Detection>& boxes){
        std::map<std::array<int,4>,int> regions;
        for(const auto& block:original["blocks"]){
            if(block["verified"].get<bool>())continue;
            bool missing=false,uncertain=false;
            for(const auto& reason:block["skip_reasons"]){missing=missing||reason=="unrecognized_ink";
                uncertain=uncertain||reason=="recognition_disagrees"||reason=="low_confidence";}
            if(!missing||!uncertain)continue;
            for(const auto& id:block["line_ids"]){const auto& line=original["lines"][id.get<int>()];
                auto r=line["white_rect"].get<std::array<int,4>>();Rect b{r[0],r[1],r[2],r[3]};
                if(b.x0<=0||b.y0<=0||b.x1>=w||b.y1>=h||b.area()>w*h*.12||std::min(b.w(),b.h())<24)continue;
                auto core=line["core_rect"].get<std::array<int,4>>();
                regions[r]=std::max(regions[r],std::min(core[2]-core[0],core[3]-core[1]));
            }
        }
        int passes=0;
        for(const auto& entry:regions){if(passes>=4)break;check(token);
            const auto& r=entry.first;Rect b{r[0],r[1],r[2],r[3]};int pad=std::max(8,entry.second);
            Rect roi{std::max(0,b.x0-pad),std::max(0,b.y0-pad),std::min(w,b.x1+pad),std::min(h,b.y1+pad)};
            double scale=std::min(2.,1280./std::max(roi.w(),roi.h()));
            int rw=std::max(16,int(std::round(roi.w()*scale))),rh=std::max(16,int(std::round(roi.h()*scale)));
            std::vector<uint8_t> pixels(size_t(rw)*rh*3);
            for(int y=0;y<rh;++y)for(int x=0;x<rw;++x)for(int c=0;c<3;++c)
                pixels[(y*rw+x)*3+c]=uint8_t(std::round(sample(rgb,w,h,roi.x0+(x+.5)*roi.w()/rw-.5,roi.y0+(y+.5)*roi.h()/rh-.5,c)));
            auto local=detect(pixels.data(),rw,rh,token);++passes;
            auto mapped=[&](Rect a){return Rect{std::max(0,roi.x0+int(std::floor(double(a.x0)*roi.w()/rw))),
                std::max(0,roi.y0+int(std::floor(double(a.y0)*roi.h()/rh))),
                std::min(w,roi.x0+int(std::ceil(double(a.x1)*roi.w()/rw))),
                std::min(h,roi.y0+int(std::ceil(double(a.y1)*roi.h()/rh)))};};
            std::vector<Detection> replacement;
            for(auto d:local){d.box=mapped(d.box);d.core=mapped(d.core);
                if(intersection(d.core,b)<d.core.area()*.8)continue;
                replacement.push_back(d);
            }
            if(replacement.empty()||replacement.size()>24)continue;
            auto inside=[&](const Detection& d){return intersection(d.core,b)>d.core.area()*.8;};
            if(boxes.size()-std::count_if(boxes.begin(),boxes.end(),inside)+replacement.size()>300)continue;
            boxes.erase(std::remove_if(boxes.begin(),boxes.end(),inside),boxes.end());
            boxes.insert(boxes.end(),replacement.begin(),replacement.end());
        }
        std::sort(boxes.begin(),boxes.end(),[](Detection a,Detection b){return a.box.y0==b.box.y0?a.box.x0<b.box.x0:a.box.y0<b.box.y0;});
        return passes;
    }

    struct Crop {Rect box;bool rotate;int cw,ch,rw,tw;
        std::array<int,6> key(bool binary=false)const{return {box.x0,box.y0,box.x1,box.y1,tw,int(binary)};}
    };
    static Crop cropInfo(int w,int h,Rect box,int padding,int minimum_width=32){
        box={std::max(0,box.x0-padding),std::max(0,box.y0-padding),std::min(w,box.x1+padding),std::min(h,box.y1+padding)};
        bool rotate=box.h()>1.5*box.w();int cw=rotate?box.h():box.w(),ch=rotate?box.w():box.h();
        int rw=std::min(1536,std::max(1,int(std::ceil(48.*cw/ch)))),tw=std::max(minimum_width,((rw+31)/32)*32);
        return {box,rotate,cw,ch,rw,tw};
    }
    static void cropPixels(const uint8_t* rgb,int w,int h,const Crop& crop,float* data,bool binary=false){
        const auto& box=crop.box;
        int threshold=0;
        if(binary){
            std::array<int,256> hist{};double sum=0;
            for(int y=box.y0;y<box.y1;++y)for(int x=box.x0;x<box.x1;++x){int p=(y*w+x)*3;
                int gray=int(.299*rgb[p]+.587*rgb[p+1]+.114*rgb[p+2]);++hist[gray];sum+=gray;}
            int count=0;double partial=0,best=-1;
            for(int t=0;t<255;++t){count+=hist[t];partial+=double(t)*hist[t];int other=box.area()-count;if(!count||!other)continue;
                double difference=partial/count-(sum-partial)/other,score=double(count)*other*difference*difference;
                if(score>best){best=score;threshold=t;}}
        }
        for(int c=0;c<3;++c)for(int y=0;y<48;++y)for(int x=0;x<crop.rw;++x){
            double xx=(x+.5)*crop.cw/crop.rw-.5,yy=(y+.5)*crop.ch/48-.5;
            double sx=crop.rotate?box.x1-1-yy:box.x0+xx,sy=crop.rotate?box.y0+xx:box.y0+yy;
            if(binary){double gray=.299*sample(rgb,w,h,sx,sy,0)+.587*sample(rgb,w,h,sx,sy,1)+.114*sample(rgb,w,h,sx,sy,2);
                data[(c*48+y)*crop.tw+x]=gray>threshold?1.f:-1.f;}
            else data[(c*48+y)*crop.tw+x]=sample(rgb,w,h,sx,sy,2-c)/127.5f-1.f;
        }
    }
    Reading decodeReading(const float* values,int steps,int classes){
        int last=-1;Reading reading;
        for(int t=0;t<steps;++t){const float* row=values+t*classes;int id=int(std::max_element(row,row+classes)-row);
            if(id&&id!=last)reading.append(alphabet[id],row[id]);last=id;}
        reading.finish();return reading;
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
    Reading recognize(const uint8_t* rgb,int w,int h,Rect box,int padding,int64_t token,int minimum_width=32,bool binary=false){
        const auto crop=cropInfo(w,h,box,padding,minimum_width);
        check(token);
        const auto key=crop.key(binary);
        auto cached=readings.find(key);
        if(cached!=readings.end()){++reading_hits;return cached->second;}
        ++reading_runs;
        std::vector<float> data(size_t(3)*48*crop.tw,0);
        cropPixels(rgb,w,h,crop,data.data(),binary);
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
    J analyzePass(const uint8_t* rgb,int w,int h,int64_t token,bool unrestricted,const std::vector<Detection>& initial,bool fine_scale){
        check(token);
        auto started=Clock::now();
        if(!rgb||w<16||h<16||w>1600||h>1600)throw std::runtime_error("page_size");
        std::vector<uint8_t> white(size_t(w)*h);
        for(size_t i=0;i<white.size();++i)white[i]=(.299*rgb[i*3]+.587*rgb[i*3+1]+.114*rgb[i*3+2])>210;
        auto whites=components(white,w,h);check(token);
        double white_ms=milliseconds(started);auto stage=Clock::now();
        auto boxes=initial;double detect_ms=0;stage=Clock::now();
        std::vector<Rect> seeds;for(const auto& d:boxes)seeds.push_back(d.core);
        if(fine_scale)fineScalePockets(whites,white,w,h,seeds);
        else for(int radius:{1,2,3,4,5}){recoverPockets(whites,white,w,h,radius,seeds);check(token);}
        white_ms+=milliseconds(stage);stage=Clock::now();
        const int full_page_detections=int(boxes.size());
        const int bubble_passes=fine_scale?0:refineBubbles(rgb,w,h,whites,boxes,token);
        detect_ms+=milliseconds(stage);stage=Clock::now();std::vector<Line> lines,candidates;
        int filtered_regions=0;
        for(const auto& detection:boxes){
            Rect box=detection.box;
            Line line;line.box=box;line.core=detection.core;line.vertical=detection.orientation?detection.orientation==1:box.h()>1.35*box.w();line.region_recovered=detection.recovered;
            std::map<int,int> votes;
            for(int y=box.y0;y<box.y1;++y)for(int x=box.x0;x<box.x1;++x)if(whites.labels[y*w+x])++votes[whites.labels[y*w+x]];
            int most=0;for(auto v:votes)if(v.second>most){most=v.second;line.white=v.first;}
            if(most<box.area()*.25)line.white=0;
            const auto& region=whites.regions[line.white];
            // These regions cannot pass the bubble gate at any confidence. Avoid
            // spending two neural runs on page furniture or open page backgrounds.
            if(!unrestricted&&(!line.white||(!bounded(region,w,h)&&!clippedBalloon(region,w,h)))){++filtered_regions;continue;}
            candidates.push_back(line);
        }
        std::map<int,std::vector<Rect>> batches;
        std::map<int,int> region_text_area;
        for(const auto& line:candidates)region_text_area[line.white]+=line.box.area();
        for(const auto& line:candidates)batches[cropInfo(w,h,line.box,0).tw].push_back(line.box);
        for(const auto& batch:batches)for(size_t i=1;i<batch.second.size();i+=2)
            primePair(rgb,w,h,batch.second[i-1],batch.second[i],token);
        for(auto line:candidates){
            Rect box=line.box;const auto& region=whites.regions[line.white];const auto& bounds=region.box;
            line.first=recognize(rgb,w,h,box,0,token);
            if(line.first.text.empty()||line.first.confidence<.5)continue;
            const bool compact=region.pixels<box.area()*12.&&region.pixels>bounds.area()*.4;
            // A short column in a multi-column balloon is not a sparse page.
            // Budget supplemental speech verification against all text support
            // in that region; final grouping/enclosure/ink gates still apply.
            line.region_context=!compact&&region.pixels<region_text_area[line.white]*12.&&region.pixels>bounds.area()*.4;
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
                // Upright digits and Latin letters within vertical text need
                // separate verification: rotated crops can confidently omit a
                // narrow 1 or I. Keep uncertain mixed-script crops out instead
                // of promoting a shortened but agreeing recovery reading.
                auto has_upright_ascii=[](const Reading& reading){auto chars=codepoints(reading.text);
                    return std::any_of(chars.begin(),chars.end(),[](uint32_t c){return (c>='0'&&c<='9')||(c>=0xff10&&c<=0xff19)||(c>='A'&&c<='Z')||(c>='a'&&c<='z');});};
                bool embedded_ascii=line.vertical&&(has_upright_ascii(line.first)||has_upright_ascii(line.second)
                    ||std::any_of(stable.begin(),stable.end(),has_upright_ascii));
                if(stable.size()>=2&&!conflict&&!embedded_ascii){line.first=stable[0];line.second=stable[1];line.crop_recovered=true;}
            }
            if(compact&&(line.first.text!=line.second.text||std::min(line.first.confidence,line.second.confidence)<.96)){
                auto has_upright_ascii=[](const Reading& r){auto cp=codepoints(r.text);return std::any_of(cp.begin(),cp.end(),[](uint32_t c){return (c>='0'&&c<='9')||(c>=0xff10&&c<=0xff19)||(c>='A'&&c<='Z')||(c>='a'&&c<='z');});};
                // DB unclip is for detection context. Its long-axis expansion
                // can pick up an outline or punctuation from the next row.
                // Recheck the detector support with two independent margins.
                if(!(line.vertical&&(has_upright_ascii(line.first)||has_upright_ascii(line.second)))){
                    auto a=recognize(rgb,w,h,line.core,2,token),b=recognize(rgb,w,h,line.core,4,token);
                    if(a.text==b.text&&std::min(a.confidence,b.confidence)>=.96
                       &&(line.first.confidence<.96||line.first.text==a.text)){
                        line.first=a;line.second=b;line.crop_recovered=true;
                    }
                    else {
                        // Otsu's standard document binarization is a bounded
                        // fallback for scan texture; two margins must agree.
                        auto clean_a=recognize(rgb,w,h,line.core,2,token,32,true),clean_b=recognize(rgb,w,h,line.core,4,token,32,true);
                        if(clean_a.text==clean_b.text&&std::min(clean_a.confidence,clean_b.confidence)>=.96
                           &&(line.first.confidence<.96||line.first.text==clean_a.text)){
                            line.first=clean_a;line.second=clean_b;line.crop_recovered=true;line.binary_verified=true;
                        }
                    }
                }
            }
            if((compact||line.region_context)&&line.first.cjk_only&&(bounded(region,w,h)||clippedBalloon(region,w,h))
               &&(line.first.text!=line.second.text||std::min(line.first.confidence,line.second.confidence)<.96)){
                // Preserve lexical text. Two later full readings may correct
                // uncertain initial punctuation, but must agree literally.
                const auto anchor=line.first;std::vector<Reading> stable;std::vector<std::array<int,6>> crops,stable_crops;
                auto keep=[&](Rect r,int padding,int width=32,bool binary=false){const auto key=cropInfo(w,h,r,padding,width).key(binary);
                    if(std::find(crops.begin(),crops.end(),key)!=crops.end())return;
                    crops.push_back(key);auto reading=recognize(rgb,w,h,r,padding,token,width,binary);
                    if(compatibleSpeechText(anchor,reading)&&speechAgreement(reading,reading)){stable.push_back(std::move(reading));stable_crops.push_back(key);}};
                auto distinct_pair=[&](){for(size_t i=0;i<stable_crops.size();++i)for(size_t j=0;j<i;++j)
                    if(stable[i].text==stable[j].text&&!std::equal(stable_crops[i].begin(),stable_crops[i].begin()+4,stable_crops[j].begin()))return std::pair<int,int>{int(j),int(i)};
                    return std::pair<int,int>{-1,-1};};
                keep(box,0);keep(box,2);
                if(distinct_pair().first<0){keep(line.core,2);keep(line.core,4);}
                if(distinct_pair().first<0){keep(line.core,2,32,true);keep(line.core,4,32,true);}
                // Recognition is sensitive to one raster pixel at small print
                // sizes. Recheck detector context as well as the tight core;
                // every accepted pair still uses distinct source rectangles.
                if(distinct_pair().first<0){keep(box,0,32,true);keep(box,2,32,true);}
                if(distinct_pair().first<0){keep(box,1);keep(box,3);}
                if(distinct_pair().first<0){keep(box,1,32,true);keep(box,3,32,true);}
                if(distinct_pair().first<0){keep(box,0,320);keep(box,2,320);keep(line.core,2,320);keep(line.core,4,320);}
                bool axis_tried=false;
                if(distinct_pair().first<0){axis_tried=true;
                    // DB core can omit faint end punctuation. Tighten only
                    // across the line, retaining its complete detector ends.
                    for(int margin:{1,3}){Rect crop=line.vertical?Rect{line.core.x0-margin,box.y0,line.core.x1+margin,box.y1}
                        :Rect{box.x0,line.core.y0-margin,box.x1,line.core.y1+margin};keep(crop,0);}}
                auto pair=distinct_pair();
                if(pair.first>=0&&speechAgreement(stable[pair.first],stable[pair.second])){
                    line.first=stable[pair.first];line.second=stable[pair.second];line.speech_verified=true;
                    line.speech_crops={stable_crops[pair.first],stable_crops[pair.second]};
                    line.binary_verified=line.binary_verified||line.speech_crops[0][5]||line.speech_crops[1][5];
                    line.axis_context=axis_tried;line.speech_anchor_text=anchor.text;line.speech_anchor_punctuation=anchor.punctuation_score;
                    line.speech_anchor_cjk=anchor.cjk_only;line.punctuation_recovered=anchor.text!=line.first.text;
                }
            }
            if(line.region_recovered&&!line.speech_verified&&(line.first.text!=line.second.text||std::min(line.first.confidence,line.second.confidence)<.96))continue;
            lines.push_back(line);
        }
        double recognize_ms=milliseconds(stage);stage=Clock::now();
        // Short square glyphs and detached punctuation inherit the orientation
        // of the enclosing balloon's long text lines, not their own aspect.
        for(auto& line:lines){
            auto cp=codepoints(line.first.text);
            if(!line.white||!bounded(whites.regions[line.white],w,h)||(cp.size()>2&&!(line.first.cjk_only&&!line.first.body_count&&cp.size()<=8))||line.box.h()>1.5*line.box.w()||line.box.w()>1.5*line.box.h()
               ||line.first.text!=line.second.text||(!line.speech_verified&&std::min(line.first.confidence,line.second.confidence)<.96))continue;
            int vertical=0,horizontal=0;
            for(const auto& other:lines)if(other.white==line.white&&other.first.text.size()>line.first.text.size()){
                double aspect=line.first.cjk_only&&!line.first.body_count?1.35:2.;
                if(other.core.h()>aspect*other.core.w())++vertical;
                if(other.core.w()>aspect*other.core.h())++horizontal;
            }
            if(vertical&&!horizontal)line.vertical=true;
            if(horizontal&&!vertical)line.vertical=false;
        }
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
            // Use glyph support for a recovered short column; unclip makes a
            // one-character column look like a different font size. Keep the
            // established proximity/overlap grouping for every region, including
            // Debug's open/shared backgrounds and independently verified rows.
            bool recovered=a.region_recovered||b.region_recovered;
            double fa=a.vertical?(recovered?a.core.w():r.w()):(recovered?a.core.h():r.h());
            double fb=b.vertical?(recovered?b.core.w():s.w()):(recovered?b.core.h():s.h()),font=(fa+fb)/2;
            bool punctuation=((a.first.cjk_only&&!a.first.body_count&&speechAgreement(a.first,a.second))
                ||(b.first.cjk_only&&!b.first.body_count&&speechAgreement(b.first,b.second)))
                &&bounded(whites.regions[a.white],w,h);
            if(std::min(fa,fb)/std::max(fa,fb)<(punctuation?.25:a.vertical?.6:.45))continue;
            bool adjacent=a.vertical?std::abs(r.cx()-s.cx())<1.65*font&&overlap(r.y0,r.y1,s.y0,s.y1)>.38*std::min(r.h(),s.h())
                                    :std::abs(r.cy()-s.cy())<1.65*font&&overlap(r.x0,r.x1,s.x0,s.x1)>.38*std::min(r.w(),s.w());
            bool fragment=a.vertical?std::abs(r.cx()-s.cx())<.28*font&&std::max(r.y0,s.y0)-std::min(r.y1,s.y1)<.7*font
                                    :std::abs(r.cy()-s.cy())<.28*font&&std::max(r.x0,s.x0)-std::min(r.x1,s.x1)<.7*font;
            if(adjacent||fragment)parent[find(int(i))]=find(int(j));
        }
        std::map<int,std::vector<int>> groups;for(size_t i=0;i<lines.size();++i)if(lines[i].ruby<0)groups[find(int(i))].push_back(int(i));

        // A bounded balloon may contain vertically separated paragraphs.
        // Establish that relationship from complete geometry, not from OCR
        // words or page labels. Preserve each paragraph's existing line order.
        std::map<int,std::vector<int>> by_region;
        for(const auto& group:groups)by_region[lines[group.second[0]].white].push_back(group.first);
        for(const auto& entry:by_region){int region=entry.first;const auto& roots=entry.second;
            if(!region||roots.size()<2||roots.size()>6)continue;
            const auto& c=whites.regions[region];Rect bounds=c.box;
            if(!(bounded(c,w,h)||clippedBalloon(c,w,h))||c.pixels<bounds.area()*.4||c.pixels>bounds.area()*.94)continue;
            const bool vertical=lines[groups[roots[0]][0]].vertical;
            bool safe=true;std::vector<Rect> cores;double smallest=1e9,largest=0;
            for(int root:roots){Rect core=lines[groups[root][0]].core;
                for(int id:groups[root]){const auto& line=lines[id];core=merge(core,line.core);
                    double font=vertical?line.core.w():line.core.h();smallest=std::min(smallest,font);largest=std::max(largest,font);
                    if(line.vertical!=vertical)safe=false;}
                cores.push_back(core);}
            if(!safe||smallest<largest*.6)continue;
            Rect combined=cores[0];for(Rect core:cores)combined=merge(combined,core);
            // Two fragments of one narrow column are not separate paragraphs.
            // Their large gap must not bypass the established missing-ink gate.
            if((vertical?combined.w():combined.h())<largest*1.6)continue;
            for(size_t a=0;a<cores.size();++a)for(size_t b=0;b<a;++b)
                if(overlap(cores[a].y0,cores[a].y1,cores[b].y0,cores[b].y1)>.35*std::min(cores[a].h(),cores[b].h()))safe=false;
            if(!safe)continue;
            std::vector<std::pair<int,int>> rows(bounds.h(),{w,0});
            for(int y=bounds.y0;y<bounds.y1;++y)for(int x=bounds.x0;x<bounds.x1;++x)if(whites.labels[y*w+x]==region){
                auto& row=rows[y-bounds.y0];row.first=std::min(row.first,x);row.second=std::max(row.second,x+1);}
            if(rectangularRim(rows,bounds.w())||silhouetteSolidity(rows)<.8)continue;
            for(int root:roots)for(int id:groups[root]){Rect core=lines[id].core;int support=0;
                for(int y=std::max(core.y0,bounds.y0);y<std::min(core.y1,bounds.y1);++y){auto row=rows[y-bounds.y0];support+=overlap(core.x0,core.x1,row.first,row.second);}
                if(support<core.area()*.98||(!clipContainsText(c,core,w,h,vertical?core.w():core.h())&&!bounded(c,w,h)))safe=false;
            }
            if(!safe)continue;
            for(size_t i=1;i<roots.size();++i){auto& target=groups[roots[0]];const auto& other=groups[roots[i]];
                target.insert(target.end(),other.begin(),other.end());groups.erase(roots[i]);}
        }
        std::vector<int> layout_group(lines.size(),-1);
        for(const auto& group:groups)for(int id:group.second)layout_group[id]=group.first;
        bool japanese=false;
        for(const auto& line:lines){auto chars=codepoints(line.first.text);if(line.first.confidence>=.94&&std::count_if(chars.begin(),chars.end(),kana)>=2)japanese=true;}
        J blocks=J::array(),raw=J::array();int accepted=0;
        for(size_t i=0;i<lines.size();++i){auto&l=lines[i];raw.push_back({{"id",i},{"rect",l.box.json()},{"core_rect",l.core.json()},{"text",l.first.text},
            {"score",l.first.confidence},{"verification_text",l.second.text},{"verification_score",l.second.confidence},{"ruby_parent",l.ruby},
            {"white_region",l.white},{"white_rect",whites.regions[l.white].box.json()},{"inset_verified",l.inset_verified},{"crop_recovered",l.crop_recovered},
            {"region_recovered",l.region_recovered},{"binary_verified",l.binary_verified},{"speech_verified",l.speech_verified},{"speech_crops",l.speech_crops},
            {"region_context",l.region_context},{"region_text_area",region_text_area[l.white]},{"white_pixels",whites.regions[l.white].pixels},
            {"axis_context",l.axis_context},{"punctuation_recovered",l.punctuation_recovered},{"speech_anchor_text",l.speech_anchor_text},
            {"speech_anchor_punctuation",l.speech_anchor_punctuation},{"speech_anchor_cjk",l.speech_anchor_cjk},
            {"body_score",l.first.body_score},{"verification_body_score",l.second.body_score},{"body_min",l.first.body_min},{"verification_body_min",l.second.body_min},
            {"body_count",l.first.body_count},{"verification_body_count",l.second.body_count},
            {"punctuation_score",l.first.punctuation_score},{"verification_punctuation_score",l.second.punctuation_score},
            {"punctuation_count",l.first.punctuation_count},{"verification_punctuation_count",l.second.punctuation_count},
            {"cjk_only",l.first.cjk_only},{"verification_cjk_only",l.second.cjk_only}});}
        for(auto& group:groups){auto ids=group.second;bool vertical=lines[ids[0]].vertical;
            std::vector<int> ordered;
            std::map<int,std::vector<int>> parts;for(int id:ids)parts[find(id)].push_back(id);
            std::vector<int> part_order;for(const auto& part:parts)part_order.push_back(part.first);
            auto top=[&](int root){int y=h;for(int id:parts[root])y=std::min(y,lines[id].core.y0);return y;};
            std::stable_sort(part_order.begin(),part_order.end(),[&](int a,int b){return top(a)<top(b);});
            for(int root:part_order){auto ids=parts[root];
            // Stable columns/rows: compare against a fixed anchor, never a pairwise fuzzy comparator.
            std::sort(ids.begin(),ids.end(),[&](int i,int j){auto a=lines[i].box,b=lines[j].box;
                double x=vertical?a.cx():a.cy(),y=vertical?b.cx():b.cy();return x==y?i<j:(vertical?x>y:x<y);});

            for(size_t at=0;at<ids.size();){size_t end=at+1;Rect anchor=lines[ids[at]].box;
                while(end<ids.size()){Rect b=lines[ids[end]].box;
                    if((vertical?std::abs(anchor.cx()-b.cx()):std::abs(anchor.cy()-b.cy()))>=.35*(vertical?std::min(anchor.w(),b.w()):std::min(anchor.h(),b.h())))break;
                    ++end;}
                std::sort(ids.begin()+at,ids.begin()+end,[&](int i,int j){Rect a=lines[i].box,b=lines[j].box;
                    int x=vertical?a.y0:a.x0,y=vertical?b.y0:b.x0;return x==y?i<j:x<y;});
                ordered.insert(ordered.end(),ids.begin()+at,ids.begin()+end);at=end;}
            }
            ids=std::move(ordered);
            Rect box=lines[ids[0]].box,core=lines[ids[0]].core;std::string text;double confidence=1,body_score=1;bool agreement=true,verified_lines=true,speech_basis=false;
            for(int id:ids){auto&l=lines[id];box=merge(box,l.box);core=merge(core,l.core);
                // Preserve word boundaries in horizontal Latin dialogue when merging OCR rows.
                auto latin=[](unsigned char c){return (c>='A'&&c<='Z')||(c>='a'&&c<='z');};
                if(!vertical&&!text.empty()&&!l.first.text.empty()&&latin(static_cast<unsigned char>(l.first.text.front()))
                   &&static_cast<unsigned char>(text.back())<128){if(text.back()=='-')text.pop_back();else text+=' ';}
                text+=l.first.text;confidence=std::min(confidence,std::min(l.first.confidence,l.second.confidence));
                agreement=agreement&&l.first.text==l.second.text;
                verified_lines=verified_lines&&(l.speech_verified||std::min(l.first.confidence,l.second.confidence)>=.96);
                speech_basis=speech_basis||l.speech_verified;
                if(l.first.body_count)body_score=std::min(body_score,std::min(l.first.body_score,l.second.body_score));}
            J reasons=J::array();if(!agreement)reasons.push_back("recognition_disagrees");if(!verified_lines)reasons.push_back("low_confidence");
            auto chars=codepoints(text);int cjk=0;for(auto c:chars)if(han(c)||kana(c))++cjk;
            int latin_count=int(std::count_if(chars.begin(),chars.end(),[](uint32_t c){return (c>='a'&&c<='z')||(c>='A'&&c<='Z');}));
            // Short replies still need the same independent OCR agreement,
            // confidence, enclosure and complete-ink checks as longer speech.
            if((cjk==0&&latin_count<2)||chars.size()>120)reasons.push_back("unsupported_text");
            if(chars.size()<2&&std::all_of(ids.begin(),ids.end(),[&](int id){return lines[id].region_recovered;}))reasons.push_back("unsupported_text");
            const int region=lines[ids[0]].white;Rect hit=box;bool enclosure=false;J rows=J::array();
            if(region){auto&c=whites.regions[region];Rect b=c.box;
                bool safe_region=bounded(c,w,h)||clipContainsText(c,core,w,h,vertical?core.w():core.h());
                // Bold horizontal handwriting fills much more of the bubble than
                // thin vertical print. Still require an enclosed, unique region,
                // complete text containment and a nonrectangular speech contour.
                double containment=double(overlap(box.x0,box.x1,b.x0,b.x1))*overlap(box.y0,box.y1,b.y0,b.y1)/box.area();
                enclosure=c.pixels>box.area()*(vertical?1.15:.4)&&b.area()>box.area()*1.05&&containment>=.9
                    &&c.pixels<std::min(box.area()*12.,w*h*.15)
                    &&safe_region&&c.pixels>b.area()*(vertical?.5:.4)&&c.pixels<b.area()*.94;
                // Detection unclip adds recognition context, not printed text.
                // Tight balloons may contain every glyph even when
                // that expanded crop crosses their border. Verify the original
                // detector support instead, with stricter containment; retain
                // the same unique enclosure and missing-ink checks below.
                double core_containment=double(overlap(core.x0,core.x1,b.x0,b.x1))*overlap(core.y0,core.y1,b.y0,b.y1)/core.area();
                if(!enclosure)enclosure=core_containment>=.98&&b.area()>core.area()*1.3
                    &&c.pixels>core.area()*(vertical?1.15:.8)&&c.pixels<std::min(core.area()*12.,w*h*.15)
                    &&safe_region&&c.pixels>b.area()*(vertical?.5:.4)&&c.pixels<b.area()*.94;
                // Separate paragraphs can span a concave neck; their union
                // rectangle includes background outside the balloon. Use actual
                // detected glyph support after individual 98% contour checks.
                if(!enclosure&&parts.size()>1){int support=0;for(int id:ids)support+=lines[id].core.area();
                    enclosure=safe_region&&core_containment>=.98&&b.area()>support*1.3
                        &&c.pixels>support*(vertical?1.15:.8)&&c.pixels<std::min(support*12.,w*h*.15)
                        &&c.pixels>b.area()*.4&&c.pixels<b.area()*.94;}
                // A connected white background shared by separate text groups
                // is not a uniquely selectable speech bubble.
                for(size_t k=0;k<lines.size();++k)if(lines[k].ruby<0&&lines[k].white==region&&layout_group[k]!=group.first)enclosure=false;
                if(enclosure){hit=b;
                    int full_rows=0;std::vector<std::pair<int,int>> silhouette;
                    for(int y=b.y0;y<b.y1;++y){int left=w,right=0;
                        for(int x=b.x0;x<b.x1;++x)if(whites.labels[y*w+x]==region){left=std::min(left,x);right=std::max(right,x+1);}
                        if(right-left>=b.w()*.95)++full_rows;
                        rows.push_back({left,right});}
                    if(cjk<3||clippedBalloon(c,w,h)){for(const auto& row:rows)silhouette.push_back({row[0],row[1]});
                        if(silhouetteSolidity(silhouette)<.8||(cjk<3&&sparsePanelCorner(silhouette,b,core,c.pixels)))reasons.push_back("non_balloon_shape");}
                    std::vector<std::pair<int,int>> rim;for(const auto& row:rows)rim.push_back({row[0],row[1]});
                    if(rectangularRim(rim,b.w()))reasons.push_back("rectangular_heading");
                    if(clippedBalloon(c,w,h)&&full_rows>b.h()*.8)reasons.push_back("rectangular_heading");
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
                Components source_ink;
                if(ink.regions.size()>1){std::vector<uint8_t> dark(unexplained.size());
                    for(int y=hit.y0;y<hit.y1;++y)for(int x=hit.x0;x<hit.x1;++x){size_t p=size_t(y*w+x)*3;
                        dark[(y-hit.y0)*hit.w()+x-hit.x0]=.299*rgb[p]+.587*rgb[p+1]+.114*rgb[p+2]<=120;}
                    source_ink=components(dark,hit.w(),hit.h());
                }
                for(size_t i=1;i<ink.regions.size();++i){const auto& c=ink.regions[i];
                    if(c.pixels>=std::max(8.,font*font*.02)&&c.box.w()>=font*.2&&c.box.h()>=font*.2){
                        int source=0;for(int y=c.box.y0;y<c.box.y1&&!source;++y)for(int x=c.box.x0;x<c.box.x1;++x)
                            if(ink.labels[y*hit.w()+x]==int(i)){source=source_ink.labels[y*hit.w()+x];break;}
                        double print=vertical?lines[ids[0]].core.w():lines[ids[0]].core.h();
                        // A row-envelope cut can turn a net/outline into a
                        // small apparent glyph. Check connectivity in original
                        // ink before treating that cut fragment as missing text.
                        if(source&&borderArtwork(source_ink.regions[source],hit.w(),hit.h(),print))continue;
                        reasons.push_back("unrecognized_ink");break;
                    }}
            }
            const bool verified=reasons.empty();
            // Geometry and transcription are separate evidence. A complete
            // balloon remains a valid hover contour when Debug intentionally
            // admits uncertain text; open/ambiguous/artwork regions do not.
            bool geometry_verified=enclosure;
            for(const auto& reason:reasons)if(reason!="recognition_disagrees"&&reason!="low_confidence"&&reason!="unsupported_text")geometry_verified=false;
            const bool eligible=verified||(unrestricted&&!chars.empty()&&chars.size()<=1000);
            // Only uncertain geometry falls back to a Debug text rectangle.
            if(!geometry_verified&&unrestricted){hit=box;rows=J::array();}
            if(eligible)++accepted;
            blocks.push_back({{"id",blocks.size()},{"rect",box.json()},{"hit_rect",hit.json()},{"hit_rows",rows},
                {"text",text},{"score",confidence},{"body_score",body_score},{"confidence_basis",speech_basis?"cjk_characters":"whole_line"},
                {"line_ids",ids},{"paragraph_count",parts.size()},{"eligible",eligible},{"verified",verified},{"geometry_verified",geometry_verified},{"skip_reasons",reasons},
                {"language",cjk==0?"en":japanese?"ja":"zh"},{"direction",vertical?"vertical_rtl":"horizontal_ltr"}});
        }
        return {{"schema_version",3},{"profile",unrestricted?"v6_small_debug_unrestricted":"v6_small_conservative_v15"},{"page_size",{w,h}},{"blocks",blocks},
            {"lines",raw},{"eligible_count",accepted},{"detected_count",lines.size()},{"filtered_open_regions",filtered_regions},{"state","ready"},
            {"full_page_detections",full_page_detections},{"bubble_passes",bubble_passes},{"recognition_runs",reading_runs},{"recognition_cache_hits",reading_hits},
            {"timings_ms",{{"model_load",load_ms},{"white_regions",white_ms},{"detection",detect_ms},{"recognition",recognize_ms},{"layout",milliseconds(stage)},{"total",milliseconds(started)}}}};
    }
    J analyze(const uint8_t* rgb,int w,int h,int64_t token,bool unrestricted=false){
        std::lock_guard<std::mutex> lock(running);check(token);
        readings.clear();reading_runs=0;reading_hits=0;
        if(!rgb||w<16||h<16||w>1600||h>1600)throw std::runtime_error("page_size");
        auto started=Clock::now(),stage=Clock::now();auto initial=detect(rgb,w,h,token);double detection_ms=milliseconds(stage);
        auto original=analyzePass(rgb,w,h,token,unrestricted,initial,true);
        auto recovered=analyzePass(rgb,w,h,token,unrestricted,initial,false);

        auto local_boxes=initial;stage=Clock::now();
        const int local_passes=localDetections(rgb,w,h,token,original,local_boxes);
        const double local_detection_ms=milliseconds(stage);
        if(local_passes){
            auto localized=analyzePass(rgb,w,h,token,unrestricted,local_boxes,true);
            int offset=int(recovered["lines"].size());
            for(auto row:localized["blocks"]){if(!row["verified"].get<bool>())continue;
                auto r=row["rect"].get<std::array<int,4>>();Rect box{r[0],r[1],r[2],r[3]};bool duplicate=false;
                bool truncated=false;
                for(const auto& line:original["lines"]){
                    if(line["white_rect"]!=row["hit_rect"]||line["ruby_parent"].get<int>()>=0)continue;
                    auto p=line["core_rect"].get<std::array<int,4>>();Rect core{p[0],p[1],p[2],p[3]};
                    if(intersection(core,box)<core.area()*.95)truncated=true;
                }
                if(truncated)continue;
                for(const auto& prior:recovered["blocks"]){if(!prior["verified"].get<bool>())continue;
                    auto p=prior["rect"].get<std::array<int,4>>();Rect other{p[0],p[1],p[2],p[3]};
                    if(intersection(box,other)>.5*std::min(box.area(),other.area()))duplicate=true;}
                if(duplicate)continue;
                for(auto& id:row["line_ids"])id=id.get<int>()+offset;
                row["local_detection_recovered"]=true;recovered["blocks"].push_back(std::move(row));
            }
            for(auto line:localized["lines"]){line["id"]=line["id"].get<int>()+offset;
                if(line["ruby_parent"].get<int>()>=0)line["ruby_parent"]=line["ruby_parent"].get<int>()+offset;
                recovered["lines"].push_back(std::move(line));}
            for(const char* key:{"white_regions","recognition","layout"})recovered["timings_ms"][key]=recovered["timings_ms"][key].get<double>()+localized["timings_ms"][key].get<double>();
        }
        recovered["timings_ms"]["detection"]=recovered["timings_ms"]["detection"].get<double>()+local_detection_ms;
        original["local_detector_passes"]=local_passes;

        // Prefer an independently verified balloon. Keep the original Debug
        // candidate for every unverified/ambiguous background instead of
        // splitting dense text into a different reading order.
        J selected=J::array();std::vector<bool> replaced(original["blocks"].size());
        const int offset=int(original["lines"].size());
        for(auto row:recovered["blocks"]){
            if(!row["verified"].get<bool>())continue;
            auto r=row["rect"].get<std::vector<int>>();Rect box{r[0],r[1],r[2],r[3]};
            std::vector<size_t> matches;bool already_verified=false,partial=false,rejected_shape=false,incomplete_replacement=false;int order=int(original["blocks"].size()+selected.size());
            for(size_t i=0;i<original["blocks"].size();++i){const auto& prior=original["blocks"][i];
                auto b=prior["rect"].get<std::vector<int>>();Rect other{b[0],b[1],b[2],b[3]};


                // When the original contour is already complete, a different
                // morphology must retain every original text column. Otherwise
                // a failed mixed-script line can disappear and leave a falsely
                // verified final column in the same balloon.
                if(prior["geometry_verified"].get<bool>()){
                    auto p=prior["hit_rect"].get<std::array<int,4>>(),q=row["hit_rect"].get<std::array<int,4>>();
                    Rect before{p[0],p[1],p[2],p[3]},after{q[0],q[1],q[2],q[3]};
                    if(intersection(before,after)>=.8*std::min(before.area(),after.area()))
                        for(const auto& id:prior["line_ids"]){const auto& line=original["lines"][id.get<int>()];
                            if(line["ruby_parent"].get<int>()>=0)continue;
                            auto c=line["core_rect"].get<std::array<int,4>>();Rect core{c[0],c[1],c[2],c[3]};
                            if(intersection(core,box)<core.area()*.95)incomplete_replacement=true;
                        }
                }

                // A re-detected row can be tighter than an incorrect original
                // crop. Replace those fragments only when every original line
                // belongs to this exact complete, verified white contour.
                bool same_contour=row.value("local_detection_recovered",false)&&!prior["line_ids"].empty();
                for(const auto& id:prior["line_ids"])if(original["lines"][id.get<int>()]["white_rect"]!=row["hit_rect"])same_contour=false;
                if(same_contour){
                    if(prior["verified"].get<bool>())already_verified=true;
                    if(prior["text"]==row["text"])for(const auto& reason:prior["skip_reasons"])if(reason=="non_balloon_shape")rejected_shape=true;
                    matches.push_back(i);order=std::min(order,int(i));continue;
                }

                if(intersection(box,other)<.5*std::min(box.area(),other.area()))continue;
                if(prior["verified"].get<bool>())already_verified=true;
                // Opening can sever artwork from a panel and make the remaining
                // white fragment look convex. Preserve an explicit non-balloon
                // decision for the same text instead of reclassifying that
                // negative solely through a different morphology scale.
                if(prior["text"]==row["text"])for(const auto& reason:prior["skip_reasons"])
                    if(reason=="non_balloon_shape")rejected_shape=true;
                if(intersection(box,other)>=other.area()*.8){matches.push_back(i);order=std::min(order,int(i));}
                else partial=true;
            }
            if(already_verified||rejected_shape||incomplete_replacement||(unrestricted&&partial))continue;
            for(size_t i:matches)replaced[i]=true;
            for(auto& id:row["line_ids"])id=id.get<int>()+offset;
            row["merge_order"]=order;selected.push_back(std::move(row));
        }
        for(size_t i=0;i<original["blocks"].size();++i)if(!replaced[i]){auto row=original["blocks"][i];row["merge_order"]=i;selected.push_back(std::move(row));}
        std::stable_sort(selected.begin(),selected.end(),[](const J& a,const J& b){return a["merge_order"].get<int>()<b["merge_order"].get<int>();});
        // Both hypotheses share the detector and per-pixel/crop memoization.
        // Retain exact line records for each selected block's verification.
        for(auto line:recovered["lines"]){line["id"]=line["id"].get<int>()+offset;
            if(line["ruby_parent"].get<int>()>=0)line["ruby_parent"]=line["ruby_parent"].get<int>()+offset;
            original["lines"].push_back(std::move(line));}
        int eligible=0;for(size_t i=0;i<selected.size();++i){selected[i].erase("merge_order");selected[i]["id"]=i;if(selected[i]["eligible"].get<bool>())++eligible;}
        original["blocks"]=std::move(selected);original["eligible_count"]=eligible;
        original["hypothesis_line_count"]=original["lines"].size();
        original["detected_count"]=std::max(original["detected_count"].get<int>(),recovered["detected_count"].get<int>());
        original["profile"]=unrestricted?"v6_small_debug_unrestricted":"v6_small_conservative_v15";
        original["bubble_passes"]=recovered["bubble_passes"];
        original["recognition_runs"]=reading_runs;original["recognition_cache_hits"]=reading_hits;
        for(const char* key:{"white_regions","recognition","layout"})original["timings_ms"][key]=original["timings_ms"][key].get<double>()+recovered["timings_ms"][key].get<double>();
        original["timings_ms"]["detection"]=detection_ms+recovered["timings_ms"]["detection"].get<double>();
        original["timings_ms"]["total"]=milliseconds(started);check(token);return original;
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
