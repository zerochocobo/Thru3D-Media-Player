#pragma once
#include "original_clip_core.h"
#include <cctype>
#include <cstring>

namespace quest::capture {
// Container headers only: no decoder, seek-to-frame, stream analysis or source copy.
inline std::vector<uint8_t> embedded_cover(const std::string& path,const std::string& ca,Control& control) {
    Input input;
    input.ctx=avformat_alloc_context();if(!input.ctx)return {};
    control.deadline=std::chrono::steady_clock::now()+std::chrono::seconds(3);
    input.ctx->interrupt_callback={Control::interrupt,&control};
    AVDictionary* options=nullptr;
    av_dict_set(&options,"tls_verify","1",0);
    if(!ca.empty())av_dict_set(&options,"ca_file",ca.c_str(),0);
    av_dict_set(&options,"rw_timeout","3000000",0);
    av_dict_set(&options,"user_agent","Thru3D (embedded cover)",0);
    const int opened=avformat_open_input(&input.ctx,path.c_str(),nullptr,&options);
    av_dict_free(&options);
    if(opened<0||control.cancelled.load())return {};
    const uint8_t* selected=nullptr;size_t length=0;int best=100;
    for(unsigned i=0;i<input.ctx->nb_streams;++i) {
        const auto* stream=input.ctx->streams[i];const auto* codec=stream->codecpar;
        const bool attached=(stream->disposition&AV_DISPOSITION_ATTACHED_PIC)!=0;
        if(!attached&&codec->codec_type!=AVMEDIA_TYPE_ATTACHMENT)continue;
        const uint8_t* data=attached?stream->attached_pic.data:codec->extradata;
        const int size=attached?stream->attached_pic.size:codec->extradata_size;
        if(!data||size<8||size>8*1024*1024)continue;
        const bool jpeg=data[0]==0xff&&data[1]==0xd8&&data[2]==0xff;
        const bool png=!std::memcmp(data,"\x89PNG\r\n\x1a\n",8);
        if(!jpeg&&!png)continue;
        auto* tag=av_dict_get(stream->metadata,"filename",nullptr,0);
        std::string name=tag?tag->value:"";
        std::transform(name.begin(),name.end(),name.begin(),[](unsigned char c){return std::tolower(c);});
        name=name.substr(name.find_last_of("/\\")==std::string::npos?0:name.find_last_of("/\\")+1);
        name=name.substr(0,name.find_last_of('.'));
        const int rank=name=="cover_land"?0:name=="cover"?1:name=="small_cover_land"?2:
            name=="small_cover"?3:name=="poster"?4:attached?5:100;
        if(rank<best){best=rank;selected=data;length=size;}
    }
    if(!selected||control.cancelled.load())return {};
    return {selected,selected+length};
}
}
