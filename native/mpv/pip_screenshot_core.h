#pragma once
// Still-only CPU projection, shared by Android JNI and the host pixel oracle.
// Reads the source bitmap without copying it; emits one composed RGBA row at a time.
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <functional>
#include <memory>
#include <stdexcept>
#include <vector>
#include <zlib.h>

namespace quest::pipshot {
constexpr double pi = 3.14159265358979323846;
constexpr size_t stride = 36;
struct Vec {
    double x=0, y=0, z=0;
    Vec operator+(Vec b) const { return {x+b.x,y+b.y,z+b.z}; }
    Vec operator-(Vec b) const { return {x-b.x,y-b.y,z-b.z}; }
    Vec operator*(double s) const { return {x*s,y*s,z*s}; }
};
inline Vec unit(Vec d) {
    const double n=std::sqrt(d.x*d.x+d.y*d.y+d.z*d.z);
    if(n<1e-12)throw std::runtime_error("Degenerate direction");
    return d*(1/n);
}
struct Image {
    const uint8_t* data=nullptr;
    int width=0,height=0,pitch=0;
    bool premultiplied=false;
    const uint8_t* pixel(int x,int y) const { return data+y*size_t(pitch)+x*4; }
};
struct Mode {
    int geometry=1; bool stereo=false,top_bottom=false,half=false,swap=false; double fov=180;
    int ew(const Image& image) const { return image.width/(stereo&&!top_bottom?2:1); }
    int eh(const Image& image) const { return image.height/(stereo&&top_bottom?2:1); }
};
struct Window {
    Vec x,y,z,anchor,left,right,forward,crop_right,up;
    double width=0,height=0,feather_x=0,feather_y=0,tangent_x=0,tangent_y=0;
    int source_eye=0,image=-1,orientation=1;
    explicit Window(const float* p):x{p[0],p[1],p[2]},y{p[3],p[4],p[5]},z{p[6],p[7],p[8]},
        anchor{p[9],p[10],p[11]},left{p[12],p[13],p[14]},right{p[15],p[16],p[17]},
        forward{p[22],p[23],p[24]},crop_right{p[25],p[26],p[27]},up{p[28],p[29],p[30]},
        width(p[18]),height(p[19]),feather_x(p[20]),feather_y(p[21]),tangent_x(p[31]),tangent_y(p[32]),
        source_eye(0),image(-1),orientation(1) {
        for(size_t i=0;i<stride;++i)if(!std::isfinite(p[i])||std::abs(p[i])>=1e8f)throw std::runtime_error("Invalid window");
        for(size_t i=33;i<36;++i)if(p[i]!=std::floor(p[i]))throw std::runtime_error("Invalid window");
        source_eye=int(p[33]);image=int(p[34]);orientation=int(p[35]);
        if(width<=0||height<=0||feather_x<0||feather_y<0||feather_x>.5||feather_y>.5||
           tangent_x<=0||tangent_y<=0||source_eye<0||source_eye>1||image< -1||image>2||orientation<1||orientation>8)
            throw std::runtime_error("Invalid window");
    }
    bool hit(Vec d,int eye,double& u,double& v) const {
        const Vec origin=eye==0?left:right;
        const Vec delta=anchor+x*d.x+y*d.y+z*d.z-origin;
        if(std::abs(delta.z)<1e-12)return false;
        const double t=-origin.z/delta.z;
        if(t<=0)return false;
        const double px=origin.x+delta.x*t,py=origin.y+delta.y*t;
        if(std::abs(px)>=width*.5||std::abs(py)>=height*.5)return false;
        u=px/width+.5;v=.5-py/height;return true;
    }
};
inline double smooth(double edge,double value) {
    const double t=std::clamp(value/std::max(edge,.00001),0.,1.);return t*t*(3-2*t);
}
inline double dot(Vec a,Vec b){return a.x*b.x+a.y*b.y+a.z*b.z;}
struct Plane { Vec normal; double offset; };
inline std::array<Plane,5> frustum(const Window& w,int eye) {
    const Vec p=eye==0?w.left:w.right;
    const double s=p.z>0?-1.:1.,hx=w.width*.5,hy=w.height*.5;
    std::array<Plane,5> planes{{{{0,0,s},-s*p.z},
        {{-s*p.z,0,s*(p.x+hx)},-s*hx*p.z},{{s*p.z,0,s*(hx-p.x)},-s*hx*p.z},
        {{0,-s*p.z,s*(p.y+hy)},-s*hy*p.z},{{0,s*p.z,s*(hy-p.y)},-s*hy*p.z}}};
    for(auto& plane:planes) {
        plane.offset+=dot(plane.normal,w.anchor);
        plane.normal={dot(plane.normal,w.x),dot(plane.normal,w.y),dot(plane.normal,w.z)};
    }
    return planes;
}
// Intersect a panorama latitude with the five ray/quad half-spaces. This avoids
// testing the whole 8K panorama against every small window; seams may yield two spans.
inline std::vector<std::pair<int,int>> spans(const std::array<Plane,5>& planes,double sy,double cy,int width,double longitude_span) {
    const double lo=-longitude_span*.5,hi=longitude_span*.5;
    std::vector<double> cuts{lo,hi};cuts.reserve(24);
    std::array<std::array<double,3>,5> terms{};
    for(size_t i=0;i<planes.size();++i) {
        const auto& p=planes[i];const double a=p.normal.x*cy,b=-p.normal.z*cy,c=p.normal.y*sy+p.offset;
        terms[i]={a,b,c};const double r=std::hypot(a,b);
        if(c+r< -1e-8)return {};
        if(r<1e-12||c>=r)continue;
        const double angle=std::asin(std::clamp(-c/r,-1.,1.)),phase=std::atan2(b,a);
        for(double root:{angle-phase,pi-angle-phase})for(int k=-2;k<=2;++k) {
            const double value=root+2*pi*k;if(value>lo&&value<hi)cuts.push_back(value);
        }
    }
    std::sort(cuts.begin(),cuts.end());
    std::vector<std::pair<int,int>> result;
    for(size_t i=1;i<cuts.size();++i) {
        const double middle=(cuts[i-1]+cuts[i])*.5;
        bool inside=true;
        for(const auto& t:terms)if(t[0]*std::sin(middle)+t[1]*std::cos(middle)+t[2]< -1e-8){inside=false;break;}
        if(!inside)continue;
        const int first=std::max(0,int(std::ceil((cuts[i-1]/longitude_span+.5)*width-.5))-1);
        const int last=std::min(width-1,int(std::floor((cuts[i]/longitude_span+.5)*width-.5))+1);
        if(first>last)continue;
        if(!result.empty()&&first<=result.back().second+1)result.back().second=std::max(last,result.back().second);
        else result.emplace_back(first,last);
    }
    return result;
}
// Exactly the inverse of video_coordinates.gdshaderinc, in one packed source eye.
inline bool direction(const Mode& mode,int ew,int eh,double u,double v,Vec& d) {
    if(mode.geometry==2) {
        const double sx=mode.stereo&&mode.half?1.:double(std::min(ew,eh))/ew;
        const double sy=mode.stereo&&mode.half?1.:double(std::min(ew,eh))/eh;
        const double ax=(u-.5)*2/sx,ay=(v-.5)*2/sy,r=std::hypot(ax,ay);
        if(r>1.)return false; // Padding outside the lens remains byte-identical.
        const double a=r*mode.fov*pi/360.,s=r>1e-12?std::sin(a)/r:0.;
        d={ax*s,-ay*s,-std::cos(a)};return true;
    }
    const double lon=(u-.5)*(mode.geometry==3?2*pi:pi),lat=(.5-v)*pi;
    d={std::sin(lon)*std::cos(lat),std::sin(lat),-std::cos(lon)*std::cos(lat)};return true;
}
inline bool coordinates(const Mode& mode,int ew,int eh,Vec value,double& u,double& v) {
    const Vec d=unit(value);
    if(mode.geometry!=2) {
        if(mode.geometry==1&&d.z>0)return false;
        u=.5+std::atan2(d.x,-d.z)/(mode.geometry==3?2*pi:pi);
        v=.5-std::asin(std::clamp(d.y,-1.,1.))/pi;return true;
    }
    const double angle=std::acos(std::clamp(-d.z,-1.,1.)),limit=mode.fov*pi/360.;
    if(angle>limit)return false;
    const double transverse=std::hypot(d.x,d.y),r=transverse>1e-12?.5*angle/(limit*transverse):0.;
    u=.5+r*d.x*(mode.stereo&&mode.half?1.:double(std::min(ew,eh))/ew);
    v=.5-r*d.y*(mode.stereo&&mode.half?1.:double(std::min(ew,eh))/eh);return true;
}
inline void orient(int orientation,double& u,double& v) {
    const double a=u,b=v;
    switch(orientation) {
        case 2:u=1-a;break;case 3:u=1-a;v=1-b;break;case 4:v=1-b;break;
        case 5:u=b;v=a;break;case 6:u=b;v=1-a;break;
        case 7:u=1-b;v=1-a;break;case 8:u=1-b;v=a;break;default:break;
    }
}
using Color=std::array<double,4>;
inline Color sample(const Image& image,int ox,int oy,int width,int height,double u,double v) {
    const double px=std::clamp(u*width-.5,0.,double(width-1)),py=std::clamp(v*height-.5,0.,double(height-1));
    const int x=int(px),y=int(py);const double fx=px-x,fy=py-y;
    Color result{};
    for(int dy=0;dy<2;++dy)for(int dx=0;dx<2;++dx) {
        const uint8_t* p=image.pixel(ox+std::min(x+dx,width-1),oy+std::min(y+dy,height-1));
        const double weight=(dx?fx:1-fx)*(dy?fy:1-fy);
        for(int c=0;c<4;++c)result[c]+=p[c]/255.*weight;
    }
    if(image.premultiplied&&result[3]>1e-8)for(int c=0;c<3;++c)result[c]=std::clamp(result[c]/result[3],0.,1.);
    return result;
}
inline double linear(double c) {return c<=.04045?c/12.92:std::pow((c+.055)/1.055,2.4);}
inline uint8_t encoded(double c) {
    c=std::clamp(c,0.,1.);return uint8_t(std::lround(255*(c<=.0031308?12.92*c:1.055*std::pow(c,1/2.4)-.055)));
}
inline void blend(uint8_t* pixel,const Color& color,double alpha,bool image) {
    for(int c=0;c<3;++c) {
        const double value=image?linear(color[c])*color[3]+.025*(1-color[3]):linear(color[c]);
        pixel[c]=encoded(value*alpha+linear(pixel[c]/255.)*(1-alpha));
    }
    pixel[3]=255;
}
class Png {
    FILE* file=nullptr;z_stream stream{};bool initialized=false;
    std::array<uint8_t,65536> compressed{};
    void write(const void* p,size_t n) {if(n&&std::fwrite(p,1,n,file)!=n)throw std::runtime_error("PNG write failed");}
    void integer(uint32_t v) {const uint8_t b[]={uint8_t(v>>24),uint8_t(v>>16),uint8_t(v>>8),uint8_t(v)};write(b,4);}
    void chunk(const char* kind,const uint8_t* p,size_t n) {
        integer(uint32_t(n));write(kind,4);write(p,n);
        auto crc=crc32(0,reinterpret_cast<const Bytef*>(kind),4);if(n)crc=crc32(crc,p,uInt(n));integer(uint32_t(crc));
    }
public:
    Png(const char* path,int width,int height) {
        file=std::fopen(path,"wb");if(!file)throw std::runtime_error("PNG open failed");
        try {
            const uint8_t signature[]={137,80,78,71,13,10,26,10};write(signature,8);
            const uint8_t ihdr[]={uint8_t(width>>24),uint8_t(width>>16),uint8_t(width>>8),uint8_t(width),
                uint8_t(height>>24),uint8_t(height>>16),uint8_t(height>>8),uint8_t(height),8,6,0,0,0};
            chunk("IHDR",ihdr,sizeof(ihdr));
            if(deflateInit(&stream,1)!=Z_OK)throw std::runtime_error("PNG compressor failed");
            initialized=true;
        }catch(...){std::fclose(file);file=nullptr;throw;}
    }
    void feed(uint8_t* p,size_t n,bool finish=false) {
        stream.next_in=p;stream.avail_in=uInt(n);
        do {
            stream.next_out=compressed.data();stream.avail_out=uInt(compressed.size());
            const int result=deflate(&stream,finish?Z_FINISH:Z_NO_FLUSH);
            if(result!=Z_OK&&result!=Z_STREAM_END)throw std::runtime_error("PNG compressor failed");
            const size_t count=compressed.size()-stream.avail_out;if(count)chunk("IDAT",compressed.data(),count);
            if(result==Z_STREAM_END)break;
        }while(stream.avail_in||stream.avail_out==0||finish);
    }
    void finish() {feed(nullptr,0,true);chunk("IEND",nullptr,0);if(std::fflush(file))throw std::runtime_error("PNG flush failed");}
    ~Png(){if(initialized)deflateEnd(&stream);if(file)std::fclose(file);}
};
inline void compose_rows(const Image& source,const std::vector<Image>& images,const Mode& mode,
    const std::vector<Window>& windows,const std::function<void(const uint8_t*)>& emit,
    const std::function<bool()>& cancelled) {
    if(!source.data||source.width<=0||source.height<=0||source.width>65535||source.height>65535||int64_t(source.width)*source.height>40*1024*1024||
       source.pitch<source.width*4||mode.geometry<1||mode.geometry>3||mode.fov<180||mode.fov>220||windows.size()>3||
       (mode.stereo&&(mode.top_bottom?source.height:source.width)%2))throw std::runtime_error("Invalid source");
    for(const auto& w:windows)if(w.image>=int(images.size()))throw std::runtime_error("Missing image");
    const int ew=mode.ew(source),eh=mode.eh(source);
    std::vector<std::array<std::array<Plane,5>,2>> clips;
    for(const auto& window:windows)clips.push_back({frustum(window,0),frustum(window,1)});
    // Longitude trigonometry is reused across every row, eye and window.
    std::vector<double> sx(ew),cx(ew);
    if(mode.geometry!=2)for(int x=0;x<ew;++x){const double lon=((x+.5)/ew-.5)*(mode.geometry==3?2*pi:pi);sx[x]=std::sin(lon);cx[x]=std::cos(lon);}
    std::vector<uint8_t> row(size_t(source.width)*4);
    std::vector<Vec> lens(mode.geometry==2?ew:0);std::vector<uint8_t> lens_valid(lens.size());
    for(int y=0;y<source.height;++y) {
        if(y%16==0&&cancelled())throw std::runtime_error("Cancelled screenshot");
        std::memcpy(row.data(),source.pixel(0,y),row.size());
        const int local_y=y%eh,packed_y=mode.stereo&&mode.top_bottom?y/eh:0;
        const double lat=(.5-(local_y+.5)/eh)*pi,sy=std::sin(lat),cy=std::cos(lat);
        if(mode.geometry==2) {
            for(int x=0;x<ew;++x)lens_valid[x]=direction(mode,ew,eh,(x+.5)/ew,(local_y+.5)/eh,lens[x]);
        }
        for(size_t index=0;index<windows.size();++index) {
            const auto& window=windows[index];
            for(int segment=0;segment<(mode.stereo&&!mode.top_bottom?2:1);++segment) {
                const int packed=mode.stereo&&!mode.top_bottom?segment:packed_y;
                const int eye=mode.stereo&&mode.swap?1-packed:packed;
                const auto ranges=mode.geometry==2?std::vector<std::pair<int,int>>{{0,ew-1}}:
                    spans(clips[index][eye],sy,cy,ew,mode.geometry==3?2*pi:pi);
                for(const auto& range:ranges)for(int local_x=range.first;local_x<=range.second;++local_x) {
                const int x=segment*ew+local_x;
                Vec d;
                if(mode.geometry==2) {if(!lens_valid[local_x])continue;d=lens[local_x];}
                else d={sx[local_x]*cy,sy,-cx[local_x]*cy};
                double u,v;if(!window.hit(d,eye,u,v))continue;
                Color color{0,0,0,1};
                if(window.image>=0) {
                    const double alpha=smooth(window.feather_x,std::min(u,1-u))*smooth(window.feather_y,std::min(v,1-v));
                    orient(window.orientation,u,v);const auto& image=images[window.image];
                    color=sample(image,0,0,image.width,image.height,u,v);
                    blend(row.data()+x*4,color,alpha,true);
                }else {
                    const double alpha=smooth(window.feather_x,std::min(u,1-u))*smooth(window.feather_y,std::min(v,1-v));
                    const Vec crop=window.forward+window.crop_right*((u-.5)*2*window.tangent_x)-window.up*((v-.5)*2*window.tangent_y);
                    if(coordinates(mode,ew,eh,crop,u,v)) {
                        const int selected=mode.stereo?window.source_eye:0;
                        color=sample(source,mode.stereo&&!mode.top_bottom?selected*ew:0,mode.stereo&&mode.top_bottom?selected*eh:0,ew,eh,u,v);
                    }
                    blend(row.data()+x*4,color,alpha,false);
                }
                }
            }
        }
        emit(row.data());
    }
    if(cancelled())throw std::runtime_error("Cancelled screenshot");
}
// Lossless host oracle and compatibility output; Android saves JPEG directly from compose_rows.
inline void compose(const Image& source,const std::vector<Image>& images,const Mode& mode,
    const std::vector<Window>& windows,const char* path,const std::function<bool()>& cancelled) {
    std::unique_ptr<Png> png;
    std::vector<uint8_t> filtered;
    compose_rows(source,images,mode,windows,[&](const uint8_t* row) {
        if(!png) {
            png=std::make_unique<Png>(path,source.width,source.height);
            filtered.resize(size_t(source.width)*4+1);filtered[0]=1;
        }
        for(size_t i=0;i+1<filtered.size();++i)filtered[i+1]=uint8_t(row[i]-(i>=4?row[i-4]:0));
        png->feed(filtered.data(),filtered.size());
    },cancelled);
    png->finish();
}
} // namespace quest::pipshot
