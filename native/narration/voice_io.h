#pragma once
#include <algorithm>
#include <cstdint>
#include <fstream>
#include <vector>
#include <cmath>
#include <cstring>
#include <stdexcept>
#include <limits>
namespace voiceio {
inline void u16(std::ostream& f,uint16_t v){char b[2]={char(v),char(v>>8)};f.write(b,2);}
inline void u32(std::ostream& f,uint32_t v){u16(f,uint16_t(v));u16(f,uint16_t(v>>16));}
inline uint16_t r16(std::istream& f){unsigned char b[2]{};f.read(reinterpret_cast<char*>(b),2);return uint16_t(b[0])|(uint16_t(b[1])<<8);}
inline uint32_t r32(std::istream& f){auto a=r16(f);return a|(uint32_t(r16(f))<<16);}
inline void wav(const std::string& path,const std::vector<float>& pcm){
    if(pcm.size()<48000*2*3||pcm.size()>48000*2*10||pcm.size()%2)throw std::runtime_error("Invalid reference duration");
    std::ofstream f(path,std::ios::binary|std::ios::trunc);f.write("RIFF",4);u32(f,uint32_t(36+pcm.size()*2));f.write("WAVEfmt ",8);u32(f,16);
    u16(f,1);u16(f,2);u32(f,48000);u32(f,192000);u16(f,4);u16(f,16);f.write("data",4);u32(f,uint32_t(pcm.size()*2));
    double energy=0;for(float x:pcm){if(!std::isfinite(x))throw std::runtime_error("Invalid audio");energy+=double(x)*x;u16(f,uint16_t(int16_t(std::lround(std::clamp(x,-1.f,1.f)*32767))));}
    if(!f||energy/pcm.size()<1e-9)throw std::runtime_error("Silent or unreadable reference");
}
inline std::vector<float> planar_wav(const std::string& path){
    std::ifstream f(path,std::ios::binary);char header[4]{};f.read(header,4);if(std::memcmp(header,"RIFF",4))throw std::runtime_error("Invalid WAV");
    auto bytes=r32(f);f.read(header,4);if(std::memcmp(header,"WAVE",4)||bytes>192000*10+36)throw std::runtime_error("Invalid WAV");
    f.read(header,4);if(std::memcmp(header,"fmt ",4)||r32(f)!=16||r16(f)!=1||r16(f)!=2||r32(f)!=48000||r32(f)!=192000||r16(f)!=4||r16(f)!=16)throw std::runtime_error("Invalid WAV format");
    f.read(header,4);auto count=r32(f);if(std::memcmp(header,"data",4)||count<192000*3||count>192000*10||count%4||bytes!=36+count)throw std::runtime_error("Invalid WAV data");
    size_t samples=count/4;std::vector<float> result(samples*2);
    for(size_t t=0;t<samples;++t)for(int c=0;c<2;++c)result[c*samples+t]=int16_t(r16(f))/32768.f;
    if(!f||f.peek()!=std::char_traits<char>::eof())throw std::runtime_error("Invalid WAV length");return result;
}
inline void codes(const std::string& path,const int32_t* data,int frames){
    if(frames<37||frames>125)throw std::runtime_error("Invalid reference frames");
    std::ofstream f(path,std::ios::binary|std::ios::trunc);f.write("T3VOICE1",8);u32(f,frames);
    for(int i=0;i<frames*16;++i){if(data[i]<0||data[i]>=1024)throw std::runtime_error("Invalid reference code");u16(f,uint16_t(data[i]));}if(!f)throw std::runtime_error("Voice write failed");
}
}
