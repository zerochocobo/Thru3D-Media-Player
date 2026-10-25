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
int main(int argc,char** argv) {
    try {
        planes_test();
        if(argc!=5)return 2;
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
