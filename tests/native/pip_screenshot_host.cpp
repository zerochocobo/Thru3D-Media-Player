#include "../../native/mpv/pip_screenshot_core.h"
#include "../../native/mpv/pip_screenshot_jpeg.h"
#include <fstream>
#include <iostream>
#include <iterator>
#include <chrono>
#include <ctime>

int main(int argc,char** argv) {
    if(argc!=6&&argc!=9)return 2;
    try {
        std::ifstream input(argv[1],std::ios::binary);
        std::vector<uint8_t> pixels{std::istreambuf_iterator<char>(input),std::istreambuf_iterator<char>()};
        const int width=std::stoi(argv[2]),height=std::stoi(argv[3]);
        if(pixels.size()!=size_t(width)*height*4)return 3;
        std::ifstream recipe(argv[5]);int geometry,stereo,tb,half,swap,fov,count;
        recipe>>geometry>>stereo>>tb>>half>>swap>>fov>>count;
        if(!recipe||count<0||count>3)return 4;
        std::vector<quest::pipshot::Window> windows;
        for(int i=0;i<count;++i){float values[36];for(auto& v:values)recipe>>v;if(!recipe)return 5;windows.emplace_back(values);}
        std::vector<uint8_t> picture;std::vector<quest::pipshot::Image> images;
        if(argc==9){std::ifstream image(argv[6],std::ios::binary);picture.assign(std::istreambuf_iterator<char>(image),std::istreambuf_iterator<char>());
            const int w=std::stoi(argv[7]),h=std::stoi(argv[8]);if(picture.size()!=size_t(w)*h*4)return 6;
            images.push_back({picture.data(),w,h,w*4,false});}
        const auto started=std::chrono::steady_clock::now();const auto cpu=std::clock();
        const quest::pipshot::Image source{pixels.data(),width,height,width*4,false};
        const quest::pipshot::Mode mode{geometry,bool(stereo),bool(tb),bool(half),bool(swap),double(fov)};
        const std::string output=argv[4];
        if(output.size()>=4&&output.substr(output.size()-4)==".jpg") {
            quest::pipshot::Jpeg jpeg(argv[4],width,height);
            quest::pipshot::compose_rows(source,images,mode,windows,[&](const uint8_t* row){jpeg.row(row);},[]{return false;});
            jpeg.finish();
        }else quest::pipshot::compose(source,images,mode,windows,argv[4],[]{return false;});
        std::cout<<"{\"compose_seconds\":"<<std::chrono::duration<double>(std::chrono::steady_clock::now()-started).count()
            <<",\"cpu_seconds\":"<<double(std::clock()-cpu)/CLOCKS_PER_SEC<<"}\n";
        return 0;
    }catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}
}
