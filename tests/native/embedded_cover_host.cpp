#include "../../native/mpv/embedded_cover_core.h"
#include <fstream>
#include <iostream>
int main(int argc,char** argv) {
    if(argc!=3)return 2;
    quest::capture::Control control;
    const auto bytes=quest::capture::embedded_cover(argv[1],"",control);
    std::ofstream output(argv[2],std::ios::binary);
    output.write(reinterpret_cast<const char*>(bytes.data()),bytes.size());
    std::cout<<"cover_bytes="<<bytes.size()<<'\n';
    return output?0:1;
}
