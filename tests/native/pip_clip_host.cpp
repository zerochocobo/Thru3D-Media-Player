#include "../../native/mpv/pip_clip_core.h"
#include <fstream>
#include <iostream>

void planes_test() {
    std::vector<uint8_t> pixels(16*8*4),y(20*8,0xcd),uv(20*4,0xcd);
    for(size_t i=0;i<pixels.size();i+=4){pixels[i]=255;pixels[i+3]=255;}
    std::array<quest::pipclip::Plane,3> planes{{{y.data(),int64_t(y.size()),20,1},{uv.data(),int64_t(uv.size()),20,2},{uv.data()+1,int64_t(uv.size()-1),20,2}}};
    quest::pipclip::compose_yuv({pixels.data(),16,8,64,false},{},{1,false,false,false,false,180},{},planes,[]{return false;});
    for(int row=0;row<8;++row)for(int x=0;x<20;++x)
        if(x<16?std::abs(int(y[row*20+x])-63)>1:y[row*20+x]!=0xcd)throw std::runtime_error("Y/padding mismatch");
    for(int row=0;row<4;++row)for(int x=0;x<20;++x)
        if(x<16?std::abs(int(uv[row*20+x])-(x%2?240:102))>1:uv[row*20+x]!=0xcd)throw std::runtime_error("UV/padding mismatch");
    bool rejected=false;try{quest::pipclip::copy_plane(pixels.data(),16,8,{y.data(),4,20,1});}catch(...){rejected=true;}
    if(!rejected)throw std::runtime_error("Short encoder plane accepted");
    std::cout<<"strided NV12 and bounds passed\n";
}
void video_window(const char* input,const char* output) {
    constexpr int w=320,h=160,bytes=w*h*4;
    std::ifstream source(input,std::ios::binary);std::ofstream raw(output,std::ios::binary);
    std::vector<uint8_t> pixels(bytes),yuv(w*h*3/2);
    std::array<quest::pipclip::Plane,3> planes{{{yuv.data(),w*h,w,1},
        {yuv.data()+w*h,w*h/4,w/2,1},{yuv.data()+w*h*5/4,w*h/4,w/2,1}}};
    // Both eyes see one fixed 2D crop from the RIGHT source eye, at yaw +45deg.
    // Its distinct animated patch is created independently by the Python fixture.
    const float q=std::sqrt(.5f);
    float recipe[]={50,0,0,0,50,0,0,0,50, 0,0,1.5f, -.0315f,0,1.5f,.0315f,0,1.5f,
        .7f,.42f,.025f,.04f, q,0,-q, q,0,q, 0,1,0, .03f,.03f, 1,-1,1};
    for(int frame=0;frame<4;++frame) {
        if(!source.read(reinterpret_cast<char*>(pixels.data()),bytes))throw std::runtime_error("Missing colored source frame");
        // A rear window has no pixels in an original 180-degree hemisphere.
        if(frame==3)for(int index:{11,14,17})recipe[index]=-1.5f;
        const std::vector<quest::pipshot::Window> windows=frame!=2?std::vector<quest::pipshot::Window>{quest::pipshot::Window(recipe)}:
            std::vector<quest::pipshot::Window>{};
        quest::pipclip::compose_yuv({pixels.data(),w,h,w*4,false},{},{frame==3?1:3,true,false,false,false,180},windows,planes,[]{return false;});
        raw.write(reinterpret_cast<const char*>(yuv.data()),yuv.size());
    }
    if(!raw)throw std::runtime_error("Composed video write failed");
    std::cout<<"animated right-eye video PiP YUV composition passed\n";
}
int main(int argc,char** argv) {
    try {
        planes_test();
        if(argc!=5)return 2;
        if(std::string(argv[1])=="compose") {video_window(argv[2],argv[3]);return 0;}
        if(std::string(argv[1])=="mux") {
            quest::pipclip::mux(argv[2],argv[3],argv[4],"{\"version\":1,\"geometry\":1,\"stereo_sbs\":true,\"fisheye_fov\":180}",[]{return false;});
            std::cout<<"mux passed\n";return 0;
        }
        quest::pipclip::Decoder decoder(argv[2]);std::ofstream raw(argv[3],std::ios::binary),times(argv[4]);
        std::vector<uint8_t> pixels(320*160*4);int count=0;int64_t previous=-1;
        for(;;) {
            auto pts=decoder.next(pixels.data(),320,160,320*4,[]{return false;});if(pts==-1)break;
            if(pts<=previous)throw std::runtime_error("Non-monotonic frame");
            previous=pts;
            raw.write(reinterpret_cast<const char*>(pixels.data()),pixels.size());times<<pts<<'\n';++count;
        }
        if(count<2)throw std::runtime_error("Missing frames");
        bool caught=false;try{decoder.next(pixels.data(),320,160,320*4,[]{return true;});}catch(...){caught=true;}
        if(!caught)throw std::runtime_error("Cancellation ignored");
        std::cout<<"decode passed: "<<count<<" frames\n";
    }catch(const std::exception& error){std::cerr<<error.what()<<'\n';return 1;}
}
