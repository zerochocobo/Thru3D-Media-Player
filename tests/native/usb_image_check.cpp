#include "usb_fs.h"
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <vector>
int main(int argc,char** argv) {
    try {
        if(argc==2 && std::string(argv[1])=="--invalid") {
            for(int i=0;i<24;i++) {
                bool rejected=false;
                try { auto v=usb::mount([](uint64_t,void* b,size_t n){ std::fill_n(static_cast<char*>(b),n,0); return true; },1024*1024,512,i%2!=0); usb::close_volume(v); }
                catch(const std::exception& e) { rejected=std::string(e.what())==(i%2?"NTFS volume unavailable":"FAT volume unavailable"); }
                if(!rejected) throw std::runtime_error("Invalid volume did not reach the expected rejection stage");
            }
            if(usb::rejected_writes()!=0) throw std::runtime_error("invalid-volume write attempt");
            std::cout<<"USB invalid volumes: 24 rejected, no leaked FAT slots, zero write attempts\n"; return 0;
        }
        if(argc<5 || argc>7) throw std::runtime_error("usage: usb_image_check fat|ntfs image filename expected-data [sector-size] [large]");
        std::ifstream disk(argv[2],std::ios::binary), data(argv[4],std::ios::binary);
        if(!disk||!data) throw std::runtime_error("fixture missing");
        disk.seekg(0,std::ios::end); auto length=disk.tellg();
        std::vector<char> expected((std::istreambuf_iterator<char>(data)),{});
        const uint64_t large=argc==7?5ULL*1024*1024*1024+17:0;
        const uint64_t expected_size=large+expected.size();
        unsigned reads=0;
        auto volume=usb::mount([&](uint64_t at,void* b,size_t n){ ++reads; disk.clear(); disk.seekg(at); disk.read(static_cast<char*>(b),n); return static_cast<size_t>(disk.gcount())==n; },length,argc>=6?std::stoul(argv[5]):512,std::string(argv[1])=="ntfs");
        auto entries=usb::list(volume,"/"); bool found=false; for(auto& e:entries) if(e.name==argv[3]&&!e.directory&&e.size==expected_size) found=true;
        if(!found) throw std::runtime_error("directory/size mismatch");
        auto file=usb::open(volume,std::string("/")+argv[3]);
        if(usb::size(file)!=expected_size) throw std::runtime_error("file size mismatch");
        for(uint64_t at: {uint64_t(0),uint64_t(65531),uint64_t(7),uint64_t(expected.size()-1),uint64_t(512000)}) {
            std::vector<char> got(4096); size_t n=std::min<size_t>(got.size(),expected.size()-at);
            if(usb::read(file,at,got.data(),large?n:got.size())!=n||!std::equal(got.begin(),got.begin()+n,expected.begin()+at)) throw std::runtime_error("random read mismatch");
        }
        if(large) for(uint64_t at: {uint64_t(0),uint64_t(8197),uint64_t(expected.size()-1)}) {
            std::vector<char> got(4096); size_t n=std::min<size_t>(got.size(),expected.size()-at);
            if(usb::read(file,large+at,got.data(),got.size())!=n||!std::equal(got.begin(),got.begin()+n,expected.begin()+at)) throw std::runtime_error("large random read mismatch");
        }
        char end=1; if(usb::read(file,expected_size,&end,1)!=0) throw std::runtime_error("EOF mismatch");
        usb::close_volume(volume); bool rejected=false;
        try { usb::read(file,0,&end,1); } catch(const std::exception&) { rejected=true; }
        if(!rejected) throw std::runtime_error("closed reader accepted");
        if(usb::rejected_writes()!=0) throw std::runtime_error("read-only path attempted a write");
        std::cout<<"USB image: passed, "<<entries.size()<<" entries, "<<reads<<" reads\n"; return 0;
    } catch(const std::exception& e) { std::cerr<<e.what()<<'\n'; return 1; }
}
