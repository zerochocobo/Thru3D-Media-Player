#include "hdr_image.h"
#include <openexr.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <map>
#include <sstream>
#include <stdexcept>

namespace thru { namespace {
void require(bool value) { if (!value) throw std::runtime_error("HDR image invalid or unsupported"); }
void ok(exr_result_t result) { require(result == EXR_ERR_SUCCESS); }
void dimensions(int64_t w, int64_t h) { require(w>0 && h>0 && w<=65535 && h<=65535 && w*h<=1000000000); }
using Visit=std::function<void(int,int,int,int,const float*)>;
thread_local size_t allocated=0;
struct alignas(std::max_align_t) Allocation { size_t size; };
void *allocate(size_t size) {
    if (size>128*1024*1024 || allocated>256*1024*1024-size) return nullptr;
    auto *p=static_cast<Allocation*>(std::malloc(sizeof(Allocation)+size));
    if (!p) return nullptr;
    p->size=size; allocated+=size; return p+1;
}
void deallocate(void *pointer) { if (pointer) { auto *p=static_cast<Allocation*>(pointer)-1; allocated-=p->size; std::free(p); } }
void quiet(exr_const_context_t, exr_result_t, const char*) {}
struct Exr {
    exr_context_t context=nullptr;
    int part=-1; exr_attr_box2i_t box={}; exr_storage_t storage=EXR_STORAGE_SCANLINE;
    std::array<std::string,4> names;
    explicit Exr(const std::string &path) {
        exr_context_initializer_t init=EXR_DEFAULT_CONTEXT_INITIALIZER;
        init.error_handler_fn=quiet; init.alloc_fn=allocate; init.free_fn=deallocate;
        init.max_image_width=65535; init.max_image_height=65535;
        init.max_tile_width=8192; init.max_tile_height=8192;
        ok(exr_start_read(&context,path.c_str(),&init));
        try {
            int count=0; ok(exr_get_count(context,&count)); require(count>0 && count<=64);
            for (int p=0;p<count;++p) {
                exr_storage_t type; ok(exr_get_storage(context,p,&type));
                if (type!=EXR_STORAGE_SCANLINE && type!=EXR_STORAGE_TILED) continue;
                const exr_attr_chlist_t *channels=nullptr; ok(exr_get_channels(context,p,&channels));
                require(channels && channels->num_channels>0 && channels->num_channels<=128);
                std::map<std::string,std::array<std::string,4>> layers;
                std::string gray;
                for (int i=0;i<channels->num_channels;++i) {
                    const auto &c=channels->entries[i];
                    if (c.x_sampling!=1 || c.y_sampling!=1) continue;
                    const std::string name(c.name.str); auto dot=name.find_last_of('.');
                    const auto component=dot==std::string::npos?name:name.substr(dot+1);
                    const auto layer=dot==std::string::npos?"":name.substr(0,dot+1);
                    auto pos=std::string("RGBA").find(component);
                    if (component.size()==1 && pos!=std::string::npos) layers[layer][pos]=name;
                    if (component=="Y" && (gray.empty() || layer.empty())) gray=name;
                }
                for (const auto &entry:layers) {
                    if (!entry.second[0].empty() && !entry.second[1].empty() && !entry.second[2].empty()) { names=entry.second; part=p; break; }
                }
                if (part<0 && !gray.empty()) { names={gray,gray,gray,""}; part=p; }
                if (part>=0) { storage=type; ok(exr_get_data_window(context,p,&box)); break; }
            }
            require(part>=0); dimensions(int64_t(box.max.x)-box.min.x+1,int64_t(box.max.y)-box.min.y+1);
        } catch (...) { exr_finish(&context); throw; }
    }
    ~Exr() { if (context) exr_finish(&context); }
    HdrInfo info() const { return {box.max.x-box.min.x+1,box.max.y-box.min.y+1,2}; }
    void scan(const Visit &visit,const std::function<void()> &check,bool analysis=false) {
        exr_decode_pipeline_t decode={}; decode.pipe_size=sizeof(decode);
        struct End { Exr *file; exr_decode_pipeline_t *decode; ~End(){exr_decoding_destroy(file->context,decode);} } end{this,&decode};
        bool initialized=false;
        auto chunk=[&](exr_chunk_info_t &ci,int x,int y) {
            check(); require(ci.width>0 && ci.height>0 && int64_t(ci.width)*ci.height<=8*1024*1024 && ci.packed_size<=128*1024*1024 && ci.unpacked_size<=128*1024*1024);
            require(x>=0 && y>=0 && int64_t(x)+ci.width<=info().width && int64_t(y)+ci.height<=info().height);
            if(analysis && ((128-y%128)%128>=ci.height || (128-x%128)%128>=ci.width)) return;
            std::vector<float> pixels(size_t(ci.width)*ci.height*4,0.f);
            for(size_t i=3;i<pixels.size();i+=4) pixels[i]=1.f;
            if (!initialized) { ok(exr_decoding_initialize(context,part,&ci,&decode)); initialized=true; }
            else ok(exr_decoding_update(context,part,&ci,&decode));
            for (int c=0;c<decode.channel_count;++c) {
                auto &channel=decode.channels[c]; channel.decode_to_ptr=nullptr;
                for(int k=0;k<4;++k) if(names[k]==channel.channel_name && !names[k].empty()) {
                    channel.user_data_type=EXR_PIXEL_FLOAT; channel.user_bytes_per_element=4;
                    channel.user_pixel_stride=16; channel.user_line_stride=ci.width*16;
                    channel.decode_to_ptr=reinterpret_cast<uint8_t*>(pixels.data()+k); break;
                }
            }
            ok(exr_decoding_choose_default_routines(context,part,&decode)); ok(exr_decoding_run(context,part,&decode));
            if(names[0]==names[1]) for(size_t i=0;i<pixels.size();i+=4) pixels[i+1]=pixels[i+2]=pixels[i];
            visit(x,y,ci.width,ci.height,pixels.data());
        };
        if(storage==EXR_STORAGE_SCANLINE) {
            for(int64_t y=box.min.y;y<=box.max.y;) {
                exr_chunk_info_t ci={}; ok(exr_read_scanline_chunk_info(context,part,int(y),&ci));
                require(ci.start_y<=y && int64_t(ci.start_y)+ci.height>y);
                chunk(ci,ci.start_x-box.min.x,ci.start_y-box.min.y); y=int64_t(ci.start_y)+ci.height;
            }
        } else {
            int32_t tw=0,th=0,nx=0,ny=0; ok(exr_get_tile_sizes(context,part,0,0,&tw,&th)); ok(exr_get_tile_counts(context,part,0,0,&nx,&ny));
            require(tw>0 && th>0 && nx>0 && ny>0 && int64_t(nx)*ny<=1000000);
            for(int ty=0;ty<ny;++ty) for(int tx=0;tx<nx;++tx) { exr_chunk_info_t ci={}; ok(exr_read_tile_chunk_info(context,part,tx,ty,0,0,&ci)); chunk(ci,tx*tw,ty*th); }
        }
    }
};
struct Radiance {
    std::ifstream input; int width=0,height=0,rows=0,columns=0; std::string axis1,axis2; bool xyz=false;
    bool line(std::string &value) {
        value.clear();
        for(int n=0;n<=65536;++n) {
            int c=input.get(); if(c==EOF)return !value.empty(); if(c=='\n')return true;
            require(n<65536); value.push_back(char(c));
        }
        return false;
    }
    explicit Radiance(const std::string &path):input(path,std::ios::binary) {
        std::string text; require(line(text)); if(!text.empty()&&text.back()=='\r')text.pop_back();
        require(text=="#?RADIANCE" || text=="#?RGBE"); bool format=false; size_t header=0;
        while(line(text)) {
            header+=text.size()+1; require(header<=65536); if(!text.empty()&&text.back()=='\r')text.pop_back();
            if(text.empty())break;
            if(text=="FORMAT=32-bit_rle_rgbe")format=true;
            if(text=="FORMAT=32-bit_rle_xyze"){format=true;xyz=true;}
        }
        require(format && line(text));
        std::istringstream sizes(text); require(bool(sizes>>axis1>>rows>>axis2>>columns));
        auto valid=[](const std::string &a){return a.size()==2&&(a[0]=='+'||a[0]=='-')&&(a[1]=='X'||a[1]=='Y');};
        require(valid(axis1)&&valid(axis2)&&axis1[1]!=axis2[1]); dimensions(rows,columns);
        width=axis1[1]=='X'?rows:columns; height=axis1[1]=='Y'?rows:columns;
    }
    uint8_t byte() { int value=input.get(); require(value!=EOF); return uint8_t(value); }
    void scan(const Visit &visit,const std::function<void()> &check,bool analysis=false) {
        std::vector<std::array<uint8_t,4>> row(columns);
        std::vector<float> pixels(size_t(columns)*4);
        for(int j=0;j<rows;++j) {
            check(); std::array<uint8_t,4> first={byte(),byte(),byte(),byte()};
            if(columns>=8 && columns<=32767 && first[0]==2 && first[1]==2 && !(first[2]&128)) {
                require((int(first[2])*256+first[3])==columns);
                for(int c=0;c<4;++c) for(int i=0;i<columns;) {
                    int count=byte(); require(count>0);
                    if(count>128) { count-=128; require(count<=columns-i); auto value=byte(); for(int n=0;n<count;++n)row[i++][c]=value; }
                    else { require(count<=columns-i); for(int n=0;n<count;++n)row[i++][c]=byte(); }
                }
            } else {
                int i=0,shift=0; auto value=first;
                while(i<columns) {
                    if(value[0]==1 && value[1]==1 && value[2]==1) {
                        require(i>0 && shift<=24); uint64_t count=uint64_t(value[3])<<shift; require(count<=uint64_t(columns-i));
                        const auto previous=row[i-1]; for(uint64_t n=0;n<count;++n)row[i++]=previous; shift+=8;
                    } else { row[i++]=value; shift=0; }
                    if(i<columns)value={byte(),byte(),byte(),byte()};
                }
            }
            int coordinate=(axis1[1]=='X'?axis1[0]=='-':axis1[0]=='+')?rows-1-j:j;
            if(analysis && coordinate%128) continue;
            for(int i=0;i<columns;++i) {
                int target=(axis2[1]=='X'?axis2[0]=='-':axis2[0]=='+')?columns-1-i:i;
                auto *p=pixels.data()+target*4; float scale=row[i][3]?std::ldexp(1.f,int(row[i][3])-136):0.f;
                float r=row[i][0]*scale,g=row[i][1]*scale,b=row[i][2]*scale;
                if(xyz) { p[0]=3.2404542f*r-1.5371385f*g-.4985314f*b; p[1]=-.969266f*r+1.8760108f*g+.041556f*b; p[2]=.0556434f*r-.2040259f*g+1.0572252f*b; }
                else {p[0]=r;p[1]=g;p[2]=b;} p[3]=1.f;
            }
            if(axis1[1]=='Y') visit(0,coordinate,width,1,pixels.data());
            else visit(coordinate,0,1,height,pixels.data());
        }
    }
};
bool is_exr(const std::string &path) { std::ifstream in(path,std::ios::binary); unsigned char b[4]={}; in.read(reinterpret_cast<char*>(b),4); return b[0]==0x76&&b[1]==0x2f&&b[2]==0x31&&b[3]==1; }
void scan(const std::string &path,const Visit &visit,const std::function<void()> &check,bool analysis=false) { if(is_exr(path)){Exr image(path);image.scan(visit,check,analysis);}else{Radiance image(path);image.scan(visit,check,analysis);} }
uint8_t tone(float value,double exposure) {
    // Uniform display conversion for preview and full-size cache. A 64 KiB table
    // avoids hundreds of millions of pow calls; quantization error is <=1 code value.
    static const auto transfer=[]{
        std::array<uint8_t,65536> values={};
        for(size_t i=0;i<values.size();++i){double v=double(i)/65535;double s=v<=.0031308?v*12.92:1.055*std::pow(v,1.0/2.4)-.055;values[i]=uint8_t(std::lround(s*255));}
        return values;
    }();
    double x=std::isnan(value)?0.0:std::clamp(double(value),0.0,1e20)*exposure;
    double mapped=std::clamp((x*(2.51*x+.03))/(x*(2.43*x+.59)+.14),0.0,1.0);
    return transfer[size_t(std::lround(mapped*65535))];
}
} // namespace
HdrInfo hdr_info(const std::string &path) { if(is_exr(path))return Exr(path).info();Radiance in(path);return {in.width,in.height,1}; }
std::vector<uint8_t> hdr_pixels(const std::string &path,int left,int top,int width,int height,int sample,const std::function<void()> &check,const std::string &cache) {
    const auto info=hdr_info(path); require(left>=0&&top>=0&&width>0&&height>0&&sample>0&&sample<=65535&&int64_t(left)+width<=info.width&&int64_t(top)+height<=info.height);
    int ow=(width+sample-1)/sample,oh=(height+sample-1)/sample; require(int64_t(ow)*oh<=8*1024*1024);
    double logs=0; uint64_t count=0;
    scan(path,[&](int x,int y,int w,int h,const float *p){
        for(int j=0;j<h;++j)if((y+j)%128==0) for(int i=0;i<w;++i)if((x+i)%128==0){
            const auto *v=p+(size_t(j)*w+i)*4; double l=.2126*std::max(0.f,v[0])+.7152*std::max(0.f,v[1])+.0722*std::max(0.f,v[2]);
            if(std::isfinite(l)&&v[3]>0){logs+=std::log(std::max(1e-6,l));++count;}
        }
    },check,true);
    const double exposure=count?std::clamp(.18/std::exp(logs/count),1e-6,1e6):1.0;
    std::vector<uint8_t> output(size_t(ow)*oh*4,0); std::fstream raw;
    if(!cache.empty()) {
        require(left==0&&top==0&&width==info.width&&height==info.height);
        raw.open(cache,std::ios::out|std::ios::binary|std::ios::trunc); require(bool(raw));
        uint8_t header[16]={'T','3','D','I'}; for(int b=0;b<4;++b){header[4+b]=uint8_t(uint32_t(info.width)>>(8*b));header[8+b]=uint8_t(uint32_t(info.height)>>(8*b));} header[12]=1;
        raw.write(reinterpret_cast<const char*>(header),16); raw.seekp(16+int64_t(info.width)*info.height*4-1);raw.put(0);require(bool(raw));
    }
    scan(path,[&](int x,int y,int w,int h,const float *p){
        std::vector<uint8_t> row(size_t(w)*4);
        for(int j=0;j<h;++j){
            check(); for(int i=0;i<w;++i){const auto *v=p+(size_t(j)*w+i)*4; float a=std::isfinite(v[3])?std::clamp(v[3],0.f,1.f):0.f;
                for(int c=0;c<3;++c)row[i*4+c]=uint8_t(std::lround(tone(v[c],exposure)*a)); row[i*4+3]=uint8_t(std::lround(a*255));}
            if(raw.is_open()){raw.seekp(16+(int64_t(y+j)*info.width+x)*4);raw.write(reinterpret_cast<const char*>(row.data()),row.size());require(bool(raw));}
            int sy=y+j-top; if(sy<0||sy>=height||sy%sample)continue;
            for(int i=0;i<w;++i){int sx=x+i-left;if(sx>=0&&sx<width&&sx%sample==0)std::memcpy(output.data()+(size_t(sy/sample)*ow+sx/sample)*4,row.data()+i*4,4);}
        }
    },check);
    if(raw.is_open()){raw.flush();require(bool(raw));} check(); return output;
}
}
