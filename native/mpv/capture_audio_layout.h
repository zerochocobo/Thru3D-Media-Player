#pragma once
#include <cstdint>
#include <sstream>
#include <string>

namespace quest::capture {
// Native PCM in Matroska has a channel count but no standard speaker mask.
// Our own recording tag restores speaker roles without mixing/reordering samples.
inline std::string audio_layout_filter(const std::string& text,int channels) {
    if(text.empty()||text.size()>10||channels<3||channels>8)return {};
    uint64_t mask=0;
    for(char c:text){if(c<'0'||c>'9')return {};mask=mask*10+unsigned(c-'0');}
    if(!mask||mask>0x3ffff)return {};
    int count=0;for(auto value=mask;value;value>>=1)count+=int(value&1);
    if(count!=channels)return {};
    std::ostringstream graph;
    graph<<"@thru_capture_layout:lavfi=[channelmap=map=";
    for(int i=0;i<channels;++i){if(i)graph<<'|';graph<<i;}
    graph<<":channel_layout=0x"<<std::hex<<mask<<']';
    return graph.str();
}
}
