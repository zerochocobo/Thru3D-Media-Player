#include "original_frame_core.h"
#include <fstream>
#include <iostream>

int main(int argc,char** argv) {
    if(argc!=4 && argc!=5)return 2;
    try {
        quest::capture::Control control;
        control.deadline=std::chrono::steady_clock::now()+std::chrono::seconds(60);
        if(argc==5)control.cancelled.store(true);
        auto frame=quest::capture::source_frame(argv[1],std::stoll(argv[2]),"",control);
        std::vector<uint8_t> rgba(size_t(frame->width)*frame->height*4);
        quest::capture::frame_rgba(*frame,rgba.data(),frame->width*4);
        std::ofstream output(argv[3],std::ios::binary);
        output.write(reinterpret_cast<const char*>(rgba.data()),std::streamsize(rgba.size()));
        if(!output)throw std::runtime_error("Output failed");
        std::cout<<"{\"width\":"<<frame->width<<",\"height\":"<<frame->height<<",\"pts_us\":"<<frame->pts<<"}\n";
    }catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}
}
