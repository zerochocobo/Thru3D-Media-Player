#include "image_core.h"
#include <avif/avif.h>
#include <webp/demux.h>
#include <webp/decode.h>
#include <libraw/libraw.h>
#include <lcms2.h>
#include <cstdio>
#include <jpeglib.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <fstream>
#include <limits>
#include <stdexcept>
#include <zlib.h>
#ifdef THRU_IMAGE_FFMPEG
extern "C" {
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libswscale/swscale.h>
}
#endif
namespace thru::image {
namespace {
void require(bool value) { if (!value) throw std::runtime_error("PHOTO_FORMAT_UNSUPPORTED"); }
void checkpoint(const Check& check) { if(check) check(); }
void dimensions(int w,int h,int64_t limit=32*1024*1024) {
    if(w<1 || h<1 || w>32768 || h>32768 || int64_t(w)*h>limit) throw std::runtime_error("PHOTO_TOO_LARGE");
}
std::vector<uint8_t> bytes(const std::string& path,size_t max=128*1024*1024) {
    std::ifstream input(path,std::ios::binary|std::ios::ate); require(bool(input));
    auto length=input.tellg(); require(length>0 && uint64_t(length)<=max);
    std::vector<uint8_t> data(static_cast<size_t>(length)); input.seekg(0); input.read(reinterpret_cast<char*>(data.data()),length);
    require(bool(input)); return data;
}
uint32_t be32(const uint8_t* p) { return (uint32_t(p[0])<<24)|(uint32_t(p[1])<<16)|(uint32_t(p[2])<<8)|p[3]; }
int exif_orientation(const uint8_t* p,size_t n) {
    if(n>=6&&!std::memcmp(p,"Exif\0\0",6)){p+=6;n-=6;}
    if(n<8)return 1;const bool little=p[0]=='I'&&p[1]=='I';
    if(!little&&!(p[0]=='M'&&p[1]=='M'))return 1;
    auto word=[&](size_t at)->uint32_t{if(at+2>n)return 0;return little?uint32_t(p[at])|(uint32_t(p[at+1])<<8):(uint32_t(p[at])<<8)|p[at+1];};
    auto dword=[&](size_t at)->uint32_t{if(at+4>n)return 0;return little?word(at)|(word(at+2)<<16):(word(at)<<16)|word(at+2);};
    const size_t table=dword(4);if(table>n||n-table<2)return 1;
    for(size_t i=0;i<std::min<size_t>(word(table),256);i++){size_t at=table+2+i*12;if(at+12>n)break;
        if(word(at)==0x112&&word(at+2)==3&&dword(at+4)==1){int value=int(word(at+8));return value>=1&&value<=8?value:1;}}
    return 1;
}
void orient(Frame& frame,int orientation) {
    if(orientation==1)return;
    const int w=frame.width,h=frame.height,dw=orientation>=5?h:w,dh=orientation>=5?w:h;
    std::vector<uint8_t> out(frame.rgba.size());
    for(int y=0;y<h;y++)for(int x=0;x<w;x++){int dx=x,dy=y;
        switch(orientation){case 2:dx=w-1-x;break;case 3:dx=w-1-x;dy=h-1-y;break;case 4:dy=h-1-y;break;
            case 5:dx=y;dy=x;break;case 6:dx=h-1-y;dy=x;break;case 7:dx=h-1-y;dy=w-1-x;break;case 8:dx=y;dy=w-1-x;break;default:break;}
        std::memcpy(out.data()+(size_t(dy)*dw+dx)*4,frame.rgba.data()+(size_t(y)*w+x)*4,4);}
    frame.rgba=std::move(out);frame.width=dw;frame.height=dh;
}
void resize(Frame& frame,int edge) {
    if(std::max(frame.width,frame.height)<=edge) return;
    const double ratio=double(edge)/std::max(frame.width,frame.height);
    const int w=std::max(1,int(frame.width*ratio)),h=std::max(1,int(frame.height*ratio));
    std::vector<uint8_t> out(size_t(w)*h*4);
    // Bilinear pixels, premultiplied during filtering so hidden RGB never creates dark fringes.
    for(int y=0;y<h;y++) for(int x=0;x<w;x++) {
        const double sx=(x+.5)*frame.width/w-.5,sy=(y+.5)*frame.height/h-.5;
        int x0=std::clamp(int(std::floor(sx)),0,frame.width-1),y0=std::clamp(int(std::floor(sy)),0,frame.height-1);
        int x1=std::min(x0+1,frame.width-1),y1=std::min(y0+1,frame.height-1);
        double fx=std::clamp(sx-x0,0.,1.),fy=std::clamp(sy-y0,0.,1.); double c[4]={};
        for(int i=0;i<4;i++) {
            const int px=(i&1)?x1:x0,py=(i&2)?y1:y0; const auto* p=frame.rgba.data()+(size_t(py)*frame.width+px)*4;
            const double weight=((i&1)?fx:1-fx)*((i&2)?fy:1-fy);
            c[3]+=p[3]*weight; for(int k=0;k<3;k++) c[k]+=p[k]*p[3]*weight;
        }
        auto* p=out.data()+(size_t(y)*w+x)*4;
        for(int k=0;k<3;k++) p[k]=uint8_t(std::clamp(std::lround(c[3]>0?c[k]/c[3]:0),0L,255L));
        p[3]=uint8_t(std::clamp(std::lround(c[3]),0L,255L));
    }
    frame.rgba=std::move(out); frame.width=w; frame.height=h;
}
float linear(float x,int transfer) {
    if(transfer==16) { // SMPTE ST2084, output luminance relative to 100 nit SDR white.
        const double p=std::pow(std::max(0.f,x),1./78.84375);
        return float(100.*std::pow(std::max(p-.8359375,0.)/std::max(18.8515625-18.6875*p,1e-9),1./.1593017578125));
    }
    if(transfer==18) return float((x<=.5?x*x/3:(std::exp((x-.55991073)/.17883277)+.28466892)/12)*10.);
    if(transfer==8) return x;
    if(transfer==1 || transfer==6 || transfer==14 || transfer==15) return x<.081?x/4.5f:std::pow((x+.099f)/1.099f,1.f/.45f);
    return x<=.04045?x/12.92f:std::pow((x+.055f)/1.055f,2.4f);
}
uint8_t srgb(float x) { x=std::max(0.f,x); return uint8_t(std::lround(std::clamp(x<=.0031308f?12.92f*x:1.055f*std::pow(x,1.f/2.4f)-.055f,0.f,1.f)*255)); }
void color_avif(const avifImage* image,const std::vector<uint16_t>& source,Frame& out) {
    out.rgba.resize(source.size());
    if(image->icc.size) {
        require(image->icc.size<=4*1024*1024);
        cmsHPROFILE from=cmsOpenProfileFromMem(image->icc.data,cmsUInt32Number(image->icc.size)),to=cmsCreate_sRGBProfile();
        cmsHTRANSFORM transform=from&&to?cmsCreateTransform(from,TYPE_RGBA_16,to,TYPE_RGBA_8,INTENT_RELATIVE_COLORIMETRIC,cmsFLAGS_COPY_ALPHA):nullptr;
        if(transform) cmsDoTransform(transform,source.data(),out.rgba.data(),cmsUInt32Number(source.size()/4));
        if(transform) cmsDeleteTransform(transform); if(from) cmsCloseProfile(from); if(to) cmsCloseProfile(to);
        require(transform!=nullptr); return;
    }
    const int transfer=image->transferCharacteristics,primaries=image->colorPrimaries;
    if((primaries==1 || primaries==2) && (transfer==13 || transfer==2)) {
        for(size_t i=0;i<source.size();i++)out.rgba[i]=uint8_t((source[i]+128)/257);
        return;
    }
    require(primaries==1 || primaries==2 || primaries==9 || primaries==12);
    require(transfer==1 || transfer==2 || transfer==6 || transfer==8 || transfer==13 || transfer==14 || transfer==15 || transfer==16 || transfer==18);
    for(size_t at=0;at<source.size();at+=4) {
        float r=linear(source[at]/65535.f,transfer),g=linear(source[at+1]/65535.f,transfer),b=linear(source[at+2]/65535.f,transfer);
        if(primaries==12) { const float a=r,c=g,d=b; r=1.224745f*a-.224904f*c; g=-.042058f*a+1.042081f*c; b=-.019642f*a-.078655f*c+1.098537f*d; }
        if(primaries==9) { const float a=r,c=g,d=b; r=1.660491f*a-.587641f*c-.072850f*d; g=-.12455f*a+1.1329f*c-.008349f*d; b=-.018151f*a-.100579f*c+1.11873f*d; }
        if(transfer==16 || transfer==18) {
            const float l=std::max(0.f,.2126f*r+.7152f*g+.0722f*b),scale=1.f/(1.f+l);
            r*=scale;g*=scale;b*=scale; // Fixed luminance mapping shared by every frame; no exposure pumping.
        }
        out.rgba[at]=srgb(r);out.rgba[at+1]=srgb(g);out.rgba[at+2]=srgb(b);out.rgba[at+3]=uint8_t((source[at+3]+128)/257);
    }
}
class Avif final:public Decoder {
    avifDecoder* decoder=nullptr;
    int edge;
public:
    Avif(const std::string& path,int limit):edge(limit) {
        decoder=avifDecoderCreate(); require(decoder!=nullptr);
        try {
            decoder->maxThreads=2;decoder->imageSizeLimit=32*1024*1024;decoder->imageDimensionLimit=32768;
            decoder->imageCountLimit=100000;decoder->allowProgressive=AVIF_FALSE;
            require(avifDecoderSetIOFile(decoder,path.c_str())==AVIF_RESULT_OK);
            require(avifDecoderParse(decoder)==AVIF_RESULT_OK);
            auto* im=decoder->image; dimensions(int(im->width),int(im->height),decoder->imageCount>1?8*1024*1024:32*1024*1024);
            info.kind=Kind::Avif;info.width=int(im->width);info.height=int(im->height);info.frames=decoder->imageCount;
            info.plays=decoder->repetitionCount==AVIF_REPETITION_COUNT_INFINITE?0:std::max<int64_t>(1,int64_t(decoder->repetitionCount)+1);
            info.alpha=decoder->alphaPresent;
            avifCropRect crop{};
            if(im->transformFlags&AVIF_TRANSFORM_CLAP) { require(avifCropRectFromCleanApertureBox(&crop,&im->clap,im->width,im->height,&decoder->diag));info.width=int(crop.width);info.height=int(crop.height); }
            if((im->transformFlags&AVIF_TRANSFORM_IROT) && (im->irot.angle&1)) std::swap(info.width,info.height);
        } catch(...) {avifDecoderDestroy(decoder);decoder=nullptr;throw;}
    }
    ~Avif() override {if(decoder) avifDecoderDestroy(decoder);}
    bool next(Frame& out,const Check& check) override {
        checkpoint(check);auto result=avifDecoderNextImage(decoder);if(result==AVIF_RESULT_NO_IMAGES_REMAINING) return false;
        require(result==AVIF_RESULT_OK);checkpoint(check);const auto* im=decoder->image;
        avifRGBImage rgb;avifRGBImageSetDefaults(&rgb,im);rgb.depth=16;rgb.format=AVIF_RGB_FORMAT_RGBA;rgb.alphaPremultiplied=AVIF_FALSE;
        std::vector<uint16_t> pixels(size_t(im->width)*im->height*4);rgb.pixels=reinterpret_cast<uint8_t*>(pixels.data());rgb.rowBytes=im->width*8;
        require(avifImageYUVToRGB(im,&rgb)==AVIF_RESULT_OK);checkpoint(check);
        Frame converted;converted.width=int(im->width);converted.height=int(im->height);color_avif(im,pixels,converted);
        std::vector<uint16_t>().swap(pixels);
        avifCropRect crop{0,0,im->width,im->height};
        if(im->transformFlags&AVIF_TRANSFORM_CLAP) require(avifCropRectFromCleanApertureBox(&crop,&im->clap,im->width,im->height,&decoder->diag));
        const int angle=(im->transformFlags&AVIF_TRANSFORM_IROT)?im->irot.angle:0;
        const bool mirror=bool(im->transformFlags&AVIF_TRANSFORM_IMIR);
        out.width=(angle&1)?int(crop.height):int(crop.width);out.height=(angle&1)?int(crop.width):int(crop.height);
        out.rgba.resize(size_t(out.width)*out.height*4);
        for(int y=0;y<int(crop.height);y++) {checkpoint(check);for(int x=0;x<int(crop.width);x++) {
            int dx=x,dy=y;
            if(angle==1){dx=y;dy=int(crop.width)-1-x;} else if(angle==2){dx=int(crop.width)-1-x;dy=int(crop.height)-1-y;} else if(angle==3){dx=int(crop.height)-1-y;dy=x;}
            if(mirror){if(im->imir.axis==0)dy=out.height-1-dy;else dx=out.width-1-dx;}
            std::memcpy(out.rgba.data()+(size_t(dy)*out.width+dx)*4,converted.rgba.data()+((size_t(crop.y)+y)*im->width+crop.x+x)*4,4);
        }}
        out.duration_us=std::max<int64_t>(1000,int64_t(std::llround((decoder->imageTiming.pts+decoder->imageTiming.duration)*1e6))-int64_t(std::llround(decoder->imageTiming.pts*1e6)));resize(out,edge);return true;
    }
    void reset() override {require(avifDecoderReset(decoder)==AVIF_RESULT_OK);}
};
class Webp final:public Decoder {
    std::vector<uint8_t> source;
    WebPAnimDecoder* decoder=nullptr;
    int last=0,edge,orientation=1,canvas_width=0,canvas_height=0;
public:
    Webp(const std::string& path,int limit):source(bytes(path,32*1024*1024)),edge(limit) {
        WebPBitstreamFeatures features{};require(WebPGetFeatures(source.data(),source.size(),&features)==VP8_STATUS_OK);
        dimensions(features.width,features.height,16*1024*1024);
        WebPData data{source.data(),source.size()};WebPAnimDecoderOptions options;require(WebPAnimDecoderOptionsInit(&options));options.color_mode=MODE_RGBA;options.use_threads=0;
        decoder=WebPAnimDecoderNew(&data,&options);require(decoder!=nullptr);
        WebPAnimInfo meta{};
        try {require(WebPAnimDecoderGetInfo(decoder,&meta));dimensions(int(meta.canvas_width),int(meta.canvas_height),16*1024*1024);require(meta.frame_count>0&&meta.frame_count<=100000);}
        catch(...){WebPAnimDecoderDelete(decoder);decoder=nullptr;throw;}
        info.kind=Kind::Webp;info.width=int(meta.canvas_width);info.height=int(meta.canvas_height);info.frames=int(meta.frame_count);info.plays=meta.loop_count;info.alpha=true;
        canvas_width=info.width;canvas_height=info.height;
        WebPChunkIterator chunk{};
        if(WebPDemuxGetChunk(WebPAnimDecoderGetDemuxer(decoder),"EXIF",1,&chunk)){orientation=exif_orientation(chunk.chunk.bytes,chunk.chunk.size);WebPDemuxReleaseChunkIterator(&chunk);}
        if(orientation>=5)std::swap(info.width,info.height);
    }
    ~Webp() override {if(decoder) WebPAnimDecoderDelete(decoder);}
    bool next(Frame& frame,const Check& check) override {
        checkpoint(check);if(!WebPAnimDecoderHasMoreFrames(decoder))return false;
        uint8_t* pixels=nullptr;int time=0;require(WebPAnimDecoderGetNext(decoder,&pixels,&time));checkpoint(check);
        frame.width=canvas_width;frame.height=canvas_height;frame.duration_us=std::max<int64_t>(10000,int64_t(time-last)*1000);last=time;
        frame.rgba.assign(pixels,pixels+size_t(canvas_width)*canvas_height*4);orient(frame,orientation);resize(frame,edge);return true;
    }
    void reset() override {WebPAnimDecoderReset(decoder);last=0;}
};
struct JpegFailure:jpeg_error_mgr {static void fail(j_common_ptr){throw std::runtime_error("PHOTO_DECODE_FAILED");}};
Frame jpeg(const unsigned char* data,size_t length,int edge) {
    jpeg_decompress_struct dec{};JpegFailure error{};dec.err=jpeg_std_error(&error);error.error_exit=JpegFailure::fail;
    jpeg_create_decompress(&dec);
    try {
        jpeg_mem_src(&dec,data,static_cast<unsigned long>(length));require(jpeg_read_header(&dec,TRUE)==JPEG_HEADER_OK);
        dimensions(int(dec.image_width),int(dec.image_height),128*1024*1024);
        dec.out_color_space=JCS_RGB;dec.scale_num=1;dec.scale_denom=1;
        while(dec.scale_denom<8 && std::max(dec.image_width,dec.image_height)/dec.scale_denom>unsigned(edge*2)) dec.scale_denom*=2;
        jpeg_start_decompress(&dec);Frame out;out.width=int(dec.output_width);out.height=int(dec.output_height);dimensions(out.width,out.height);
        out.rgba.resize(size_t(out.width)*out.height*4);std::vector<uint8_t> row(size_t(out.width)*3);
        while(dec.output_scanline<dec.output_height){const int y=int(dec.output_scanline);JSAMPROW scan=row.data();jpeg_read_scanlines(&dec,&scan,1);
            for(int x=0;x<out.width;x++){auto* p=out.rgba.data()+(size_t(y)*out.width+x)*4;std::memcpy(p,row.data()+size_t(x)*3,3);p[3]=255;}}
        jpeg_finish_decompress(&dec);jpeg_destroy_decompress(&dec);resize(out,edge);return out;
    } catch(...) {jpeg_destroy_decompress(&dec);throw;}
}
class Raw final:public Decoder {
    LibRaw raw;
    int edge;bool preview,done=false;
    const Check* active=nullptr;
    static int progress(void* context,LibRaw_progress,int,int) {
        auto* self=static_cast<Raw*>(context);try {if(self->active)checkpoint(*self->active);return 0;}catch(...){return 1;}
    }
public:
    Raw(const std::string& path,int limit,bool thumb):edge(limit),preview(thumb) {
        raw.imgdata.rawparams.max_raw_memory_mb=192;
        require(raw.open_file(path.c_str())==LIBRAW_SUCCESS && raw.imgdata.idata.raw_count>0);
        auto& size=raw.imgdata.sizes;dimensions(size.width,size.height,128*1024*1024);
        info.kind=Kind::Raw;info.width=size.width;info.height=size.height;info.preview=preview;
        info.orientation=size.flip==3?3:size.flip==5?8:size.flip==6?6:1;
        raw.imgdata.rawparams.max_raw_memory_mb=192;raw.imgdata.params.output_bps=8;raw.imgdata.params.output_color=1;
        raw.imgdata.params.use_camera_wb=1;raw.imgdata.params.no_auto_bright=1;raw.imgdata.params.user_flip=0;
        raw.imgdata.params.user_qual=0;raw.set_progress_handler(progress,this);
    }
    bool next(Frame& out,const Check& check) override {
        if(done)return false;checkpoint(check);active=&check;
        struct End {Raw* self;~End(){self->active=nullptr;}}end{this};
        const int64_t pixels=int64_t(raw.imgdata.sizes.raw_width)*raw.imgdata.sizes.raw_height;
        if(std::max(info.width,info.height)>edge*2)raw.imgdata.params.half_size=1;
        if(pixels*18>384LL*1024*1024 && raw.imgdata.idata.filters)raw.imgdata.params.half_size=1;
        const bool reduced=raw.imgdata.params.half_size && raw.imgdata.idata.filters;
        const int64_t processed=reduced?(pixels+3)/4:pixels;
        bool thumbnail=preview || pixels*4+processed*14>384LL*1024*1024;
        if(thumbnail) {
            require(raw.unpack_thumb()==LIBRAW_SUCCESS);int code=0;
            std::unique_ptr<libraw_processed_image_t,decltype(&LibRaw::dcraw_clear_mem)> image(raw.dcraw_make_mem_thumb(&code),&LibRaw::dcraw_clear_mem);
            require(image && code==0);
            if(image->type==LIBRAW_IMAGE_JPEG) out=jpeg(image->data,image->data_size,edge);
            else {require(image->bits==8 && image->colors==3);out.width=image->width;out.height=image->height;dimensions(out.width,out.height);
                out.rgba.resize(size_t(out.width)*out.height*4);for(size_t i=0;i<size_t(out.width)*out.height;i++){std::memcpy(out.rgba.data()+i*4,image->data+i*3,3);out.rgba[i*4+3]=255;}resize(out,edge);}
            info.preview=true;
        } else {
            require(raw.unpack()==LIBRAW_SUCCESS);checkpoint(check);require(raw.dcraw_process()==LIBRAW_SUCCESS);checkpoint(check);int code=0;
            std::unique_ptr<libraw_processed_image_t,decltype(&LibRaw::dcraw_clear_mem)> image(raw.dcraw_make_mem_image(&code),&LibRaw::dcraw_clear_mem);
            require(image && code==0 && image->type==LIBRAW_IMAGE_BITMAP && image->bits==8 && image->colors==3);
            out.width=image->width;out.height=image->height;dimensions(out.width,out.height);out.rgba.resize(size_t(out.width)*out.height*4);
            for(int y=0;y<out.height;y++){checkpoint(check);for(int x=0;x<out.width;x++){size_t i=size_t(y)*out.width+x;std::memcpy(out.rgba.data()+i*4,image->data+i*3,3);out.rgba[i*4+3]=255;}}
            resize(out,edge);
        }
        done=true;checkpoint(check);return true;
    }
    void reset() override {done=false;}
};
#ifdef THRU_IMAGE_FFMPEG
class Ffmpeg final:public Decoder {
    std::string path;int edge,stream=-1;
    AVFormatContext* format=nullptr;AVCodecContext* codec=nullptr;AVPacket* packet=nullptr;AVFrame* frame=nullptr;SwsContext* scaler=nullptr;
    bool draining=false;
    void clear(){sws_freeContext(scaler);scaler=nullptr;av_frame_free(&frame);av_packet_free(&packet);avcodec_free_context(&codec);avformat_close_input(&format);}
    void initialize() {
        try {AVDictionary* options=nullptr;av_dict_set(&options,"ignore_loop","1",0);av_dict_set(&options,"max_pixels","16777216",0);
            int code=avformat_open_input(&format,path.c_str(),nullptr,&options);av_dict_free(&options);require(code>=0);
            std::vector<AVDictionary*> probe_options(format->nb_streams,nullptr);
            for(auto& option:probe_options){av_dict_set(&option,"max_pixels","16777216",0);av_dict_set(&option,"threads","1",0);}
            code=avformat_find_stream_info(format,probe_options.data());for(auto& option:probe_options)av_dict_free(&option);require(code>=0);
            stream=av_find_best_stream(format,AVMEDIA_TYPE_VIDEO,-1,-1,nullptr,0);require(stream>=0);
            auto* parameters=format->streams[stream]->codecpar;dimensions(parameters->width,parameters->height,16*1024*1024);
            require(parameters->codec_id==AV_CODEC_ID_GIF || parameters->codec_id==AV_CODEC_ID_APNG);
            const AVCodec* decoder=avcodec_find_decoder(parameters->codec_id);require(decoder!=nullptr);codec=avcodec_alloc_context3(decoder);require(codec!=nullptr);
            require(avcodec_parameters_to_context(codec,parameters)>=0);codec->thread_count=1;codec->max_pixels=16*1024*1024;
            require(avcodec_open2(codec,decoder,nullptr)>=0);packet=av_packet_alloc();frame=av_frame_alloc();require(packet&&frame);draining=false;
            info.width=parameters->width;info.height=parameters->height;info.alpha=true;
            info.frames=int(std::clamp<int64_t>(format->streams[stream]->nb_frames,0,100000));
            if(info.frames==0)info.frames=2; // Unknown duration is a streaming animation, not a still.
        }catch(...){clear();throw;}
    }
public:
    Ffmpeg(const std::string& source,int limit,Kind kind):path(source),edge(limit){try{info.kind=kind;
        auto data=bytes(path,32*1024*1024);info.plays=1;
        // Validate canvas and animation structure before FFmpeg can probe/decode a frame.
        if(kind==Kind::Gif){require(data.size()>=13);dimensions(int(data[6])|(int(data[7])<<8),int(data[8])|(int(data[9])<<8),16*1024*1024);}
        else{require(data.size()>=24);dimensions(int(be32(data.data()+16)),int(be32(data.data()+20)),16*1024*1024);}
        if(kind==Kind::Apng){uint32_t sequence=0,frames=0;bool animation=false,ended=false;
            for(size_t at=8;at+12<=data.size();){uint32_t n=be32(data.data()+at);require(n<=data.size()-at-12);
                const auto* tag=data.data()+at+4;const auto* payload=tag+4;
                require(uint32_t(crc32(0,tag,n+4))==be32(payload+n));
                if(!std::memcmp(tag,"acTL",4)){require(n==8&&!animation);animation=true;info.frames=int(be32(payload));info.plays=be32(payload+4);require(info.frames>0&&info.frames<=100000);}
                if(!std::memcmp(tag,"fcTL",4)){require(animation&&n==26&&be32(payload)==sequence++);frames++;}
                if(!std::memcmp(tag,"fdAT",4))require(animation&&n>=4&&be32(payload)==sequence++);
                if(!std::memcmp(tag,"IEND",4)){require(n==0);ended=true;break;}at+=size_t(n)+12;
            }
            require(animation&&ended&&frames==uint32_t(info.frames));}
        else {require(data.size()>=13);size_t at=13+((data[10]&128)?3*(size_t(2)<<(data[10]&7)):0);int count=0;bool ended=false;
            auto blocks=[&](size_t pos){for(;;){require(pos<data.size());size_t n=data[pos++];if(!n)return pos;require(n<=data.size()-pos);pos+=n;}};
            while(at<data.size()){
                if(data[at]==0x3b){ended=true;break;}
                if(data[at]==0x21){require(data.size()-at>=3);size_t end=blocks(at+2);
                    if(data[at+1]==0xff && end-at>=19 && data[at+2]==11 &&
                        (!std::memcmp(data.data()+at+3,"NETSCAPE2.0",11)||!std::memcmp(data.data()+at+3,"ANIMEXTS1.0",11)) && data[at+14]==3 && data[at+15]==1){
                        unsigned loops=unsigned(data[at+16])|(unsigned(data[at+17])<<8);info.plays=loops?int64_t(loops)+1:0;}
                    at=end;
                }else if(data[at]==0x2c){require(data.size()-at>=10);size_t palette=(data[at+9]&128)?3*(size_t(2)<<(data[at+9]&7)):0;
                    require(palette+11<=data.size()-at);at=blocks(at+11+palette);require(++count<=100000);
                }else require(false);
            }
            require(ended&&count>0);info.frames=count;}
        auto saved=info;initialize();info.frames=saved.frames;info.plays=saved.plays;
    }catch(...){clear();throw;}}
    ~Ffmpeg() override {clear();}
    bool next(Frame& out,const Check& check) override {
        for(;;){checkpoint(check);int code=avcodec_receive_frame(codec,frame);
            if(code>=0)break;if(code==AVERROR_EOF)return false;require(code==AVERROR(EAGAIN));
            if(draining)return false;
            do {av_packet_unref(packet);code=av_read_frame(format,packet);checkpoint(check);}while(code>=0 && packet->stream_index!=stream);
            if(code<0){require(code==AVERROR_EOF);require(avcodec_send_packet(codec,nullptr)>=0);draining=true;}
            else {code=avcodec_send_packet(codec,packet);av_packet_unref(packet);require(code>=0);}
        }
        dimensions(frame->width,frame->height,16*1024*1024);require(frame->width==info.width&&frame->height==info.height);
        double ratio=std::min(1.,double(edge)/std::max(frame->width,frame->height));
        out.width=std::max(1,int(frame->width*ratio));out.height=std::max(1,int(frame->height*ratio));out.rgba.resize(size_t(out.width)*out.height*4);
        scaler=sws_getCachedContext(scaler,frame->width,frame->height,static_cast<AVPixelFormat>(frame->format),out.width,out.height,AV_PIX_FMT_RGBA,SWS_BILINEAR,nullptr,nullptr,nullptr);require(scaler!=nullptr);
        uint8_t* planes[]={out.rgba.data(),nullptr,nullptr,nullptr};int strides[]={out.width*4,0,0,0};require(sws_scale(scaler,frame->data,frame->linesize,0,frame->height,planes,strides)==out.height);
        const AVRational timebase=format->streams[stream]->time_base;
        out.duration_us=frame->pts!=AV_NOPTS_VALUE&&frame->duration>0&&frame->pts<=INT64_MAX-frame->duration?
            av_rescale_q(frame->pts+frame->duration,timebase,AVRational{1,1000000})-av_rescale_q(frame->pts,timebase,AVRational{1,1000000}):av_rescale_q(frame->duration,timebase,AVRational{1,1000000});
        if(out.duration_us<=0 || (info.kind==Kind::Gif && out.duration_us<=10000))out.duration_us=100000;
        av_frame_unref(frame);return true;
    }
    void reset() override {auto saved=info;clear();initialize();info=saved;}
};
#endif
}
Kind sniff(const std::string& path,bool raw_hint) {
    std::ifstream input(path,std::ios::binary);std::array<uint8_t,65536> prefix{};input.read(reinterpret_cast<char*>(prefix.data()),prefix.size());size_t n=size_t(input.gcount());if(n<12)return Kind::Unknown;
    avifROData data{prefix.data(),n};if(avifPeekCompatibleFileType(&data))return Kind::Avif;
    if(!std::memcmp(prefix.data(),"GIF87a",6)||!std::memcmp(prefix.data(),"GIF89a",6))return Kind::Gif;
    if(!std::memcmp(prefix.data(),"RIFF",4)&&!std::memcmp(prefix.data()+8,"WEBP",4))return n>20&&!std::memcmp(prefix.data()+12,"VP8X",4)&&(prefix[20]&2)?Kind::Webp:Kind::Unknown;
    if(!std::memcmp(prefix.data(),"\x89PNG\r\n\x1a\n",8)){
        input.clear();input.seekg(0,std::ios::end);const auto length=input.tellg();uint64_t at=8;
        // Ancillary ICC/text chunks may exceed the prefix. Skip their payload,
        // reading only bounded headers before IDAT; never load a PNG to classify it.
        for(int chunks=0;chunks<4096 && length>=0 && at+12<=uint64_t(length);chunks++){
            std::array<uint8_t,8> chunk{};input.seekg(std::streamoff(at));input.read(reinterpret_cast<char*>(chunk.data()),8);if(!input)break;
            uint32_t len=be32(chunk.data());if(uint64_t(len)+12>uint64_t(length)-at)break;
            if(!std::memcmp(chunk.data()+4,"acTL",4))return len==8?Kind::Apng:Kind::Unknown;
            if(!std::memcmp(chunk.data()+4,"IDAT",4)||!std::memcmp(chunk.data()+4,"IEND",4))break;at+=uint64_t(len)+12;
        }return Kind::Unknown;}
    const bool tiff=(prefix[0]=='I'&&prefix[1]=='I')||(prefix[0]=='M'&&prefix[1]=='M');
    const bool container=!std::memcmp(prefix.data()+4,"ftyp",4),fuji=!std::memcmp(prefix.data(),"FUJIFILM",8);
    if(raw_hint||tiff||container||fuji){try{auto info=raw_info(path);if(info.width>0)return Kind::Raw;}catch(...) {}}
    return Kind::Unknown;
}
Info raw_info(const std::string& path){Raw decoder(path,512,true);return decoder.info;}
std::unique_ptr<Decoder> open(const std::string& path,int edge,bool preview,const Check& check){
    require(edge>=64 && edge<=8192);checkpoint(check);switch(sniff(path,true)){
        case Kind::Avif:return std::make_unique<Avif>(path,edge);
        case Kind::Webp:return std::make_unique<Webp>(path,edge);
        case Kind::Raw:return std::make_unique<Raw>(path,edge,preview);
#ifdef THRU_IMAGE_FFMPEG
        case Kind::Gif:return std::make_unique<Ffmpeg>(path,edge,Kind::Gif);
        case Kind::Apng:return std::make_unique<Ffmpeg>(path,edge,Kind::Apng);
#endif
        default:throw std::runtime_error("PHOTO_FORMAT_UNSUPPORTED");
    }
}
}
