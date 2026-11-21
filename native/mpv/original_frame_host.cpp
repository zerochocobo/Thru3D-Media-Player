#include "video_thumbnail_core.h"
#include "embedded_cover_core.h"
#include <fstream>
#include <iostream>

int main(int argc,char** argv) {
    if(argc!=4 && argc!=5)return 2;
    try {
        const std::string mode(argv[2]);
        if (mode == "thumbnail" || mode == "prefix") {
            const bool seekable = mode == "thumbnail";
            std::ifstream media(argv[1], std::ios::binary | std::ios::ate);
            const int64_t size = media.tellg();
            media.seekg(0);
            int64_t read = 0;
            quest::capture::ThumbnailInput input{
                seekable ? size : -1, std::stoll(argv[3]),
                [&](int64_t offset, uint8_t* buffer, int count) {
                    if (!seekable && offset != read) return -1;
                    media.clear();
                    media.seekg(offset);
                    media.read(reinterpret_cast<char*>(buffer), count);
                    read += media.gcount();
                    return int(media.gcount());
                },
                [=] { return argc == 5; },
                40LL * 1024 * 1024, seekable
            };
            if (!input.open()) {
                std::cout << "{\"decoded\":false,\"bytes\":" << read << ",\"reads\":" << input.reads << "}\n";
                return 0;
            }
            const auto cover = quest::capture::find_embedded_cover(*input.format, 512 * 1024);
            auto picture = cover.data ? quest::capture::Frame(nullptr, nullptr) : quest::capture::thumbnail_frame(input);
            std::vector<uint8_t> rgba(320 * 180 * 4);
            if (picture) quest::capture::frame_rgba(*picture, rgba.data(), 320 * 4, 320, 180);
            const bool visible = std::any_of(rgba.begin(), rgba.end(), [](uint8_t value) { return value > 0 && value < 255; });
            std::cout << "{\"decoded\":" << (visible ? "true" : "false")
                      << ",\"cover_bytes\":" << cover.size << ",\"bytes\":" << read
                      << ",\"reads\":" << input.reads << "}\n";
            return 0;
        }
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
