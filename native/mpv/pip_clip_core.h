#pragma once
#include "original_frame_core.h"
#include "pip_screenshot_core.h"

namespace quest::pipclip {
struct Plane {uint8_t* pixels;int64_t capacity;int row,stride;};
inline void copy_plane(const uint8_t* source,int width,int height,const Plane& plane) {
    if(!source||!plane.pixels||width<=0||height<=0||plane.stride<1||plane.stride>2||
       plane.row<(width-1)*plane.stride+1||plane.capacity<int64_t(height-1)*plane.row+(width-1)*plane.stride+1)
        throw std::runtime_error("Invalid encoder plane");
    for(int y=0;y<height;++y)for(int x=0;x<width;++x)plane.pixels[size_t(y)*plane.row+x*plane.stride]=source[size_t(y)*width+x];
}
inline void compose_yuv(const pipshot::Image& source,const std::vector<pipshot::Image>& images,const pipshot::Mode& mode,
    const std::vector<pipshot::Window>& windows,const std::array<Plane,3>& planes,const std::function<bool()>& cancelled) {
    const int w=source.width,h=source.height;
    if(w<=0||h<=0||w>3840||h>3840||w%4||h%4)throw std::runtime_error("Invalid encoder size");
    std::vector<uint8_t> rgba(size_t(w)*h*4),yuv(size_t(w)*h*3/2);size_t offset=0;
    pipshot::compose_rows(source,images,mode,windows,[&](const uint8_t* line){std::memcpy(rgba.data()+offset,line,size_t(w)*4);offset+=size_t(w)*4;},cancelled);
    auto* scaler=sws_getContext(w,h,AV_PIX_FMT_RGBA,w,h,AV_PIX_FMT_YUV420P,SWS_BILINEAR,nullptr,nullptr,nullptr);
    if(!scaler)throw std::bad_alloc();
    std::unique_ptr<SwsContext,decltype(&sws_freeContext)> owned(scaler,sws_freeContext);
    const int* coefficients=sws_getCoefficients(SWS_CS_ITU709);
    capture::check(sws_setColorspaceDetails(scaler,coefficients,1,coefficients,0,0,1<<16,1<<16));
    const uint8_t* in[]={rgba.data(),nullptr,nullptr,nullptr};const int ip[]={w*4,0,0,0};
    uint8_t* out[]={yuv.data(),yuv.data()+size_t(w)*h,yuv.data()+size_t(w)*h*5/4,nullptr};const int op[]={w,w/2,w/2,0};
    if(sws_scale(scaler,in,ip,0,h,out,op)!=h)throw std::runtime_error("Frame conversion failed");
    for(int i=0;i<3;++i)copy_plane(out[i],i?w/2:w,i?h/2:h,planes[i]);
}
// Only the private, completed live recording is opened. No URI resolver or second network reader.
struct Local {
    capture::Input input;
    explicit Local(const std::string& path) {
        AVDictionary* options=nullptr;av_dict_set(&options,"protocol_whitelist","file",0);
        const int result=avformat_open_input(&input.ctx,path.c_str(),nullptr,&options);
        av_dict_free(&options);capture::check(result);capture::check(avformat_find_stream_info(input.ctx,nullptr));
    }
};
struct Decoder {
    Local local;
    capture::FrameDecoder decoder;
    capture::Frame frame=capture::frame();
    capture::Packet packet=capture::packet();
    int video=-1;bool flushing=false;int64_t bucket=-1;
    explicit Decoder(const std::string& path):local(path) {
        video=av_find_best_stream(local.input.ctx,AVMEDIA_TYPE_VIDEO,-1,-1,nullptr,0);capture::check(video);
        auto* stream=local.input.ctx->streams[video];capture::frame_size(stream->codecpar->width,stream->codecpar->height);
        auto* codec=avcodec_find_decoder(stream->codecpar->codec_id);if(!codec)throw std::runtime_error("Decoder unavailable");
        decoder.ctx=avcodec_alloc_context3(codec);if(!decoder.ctx||!frame||!packet)throw std::bad_alloc();
        capture::check(avcodec_parameters_to_context(decoder.ctx,stream->codecpar));
        decoder.ctx->pkt_timebase=stream->time_base;decoder.ctx->thread_count=2;decoder.ctx->max_pixels=40LL*1024*1024;
        capture::check(avcodec_open2(decoder.ctx,codec,nullptr));
    }
    int64_t next(uint8_t* pixels,int width,int height,int pitch,const std::function<bool()>& cancelled) {
        for(;;) {
            if(cancelled())throw std::runtime_error("Clip export cancelled");
            const int received=avcodec_receive_frame(decoder.ctx,frame.get());
            if(received==AVERROR_EOF)return -1;
            if(received>=0) {
                capture::frame_size(frame->width,frame->height);
                const auto time_base=local.input.ctx->streams[video]->time_base;
                const auto time=capture::micros(frame->best_effort_timestamp,time_base)-local.input.origin();
                if(frame->best_effort_timestamp==AV_NOPTS_VALUE)throw std::runtime_error("Missing frame timestamp");
                // Matroska rounds 33.333 ms to 33 ms: do not mistake that frame for the
                // previous 30 Hz slot and select 50 ms instead (visible cadence jitter).
                const auto tolerance=std::max<int64_t>(1,capture::micros(1,time_base)/2+1);
                const auto selected=(time+tolerance)*30/1000000;
                if(time<0||selected<=bucket){av_frame_unref(frame.get());continue;}
                // No implicit HDR-to-SDR claim: the existing still converter is not a tone mapper.
                if(frame->color_trc==AVCOL_TRC_SMPTE2084||frame->color_trc==AVCOL_TRC_ARIB_STD_B67)
                    throw std::runtime_error("HDR picture in picture recording unavailable");
                bucket=selected;
                auto* scaler=sws_getContext(frame->width,frame->height,static_cast<AVPixelFormat>(frame->format),width,height,AV_PIX_FMT_RGBA,SWS_BILINEAR,nullptr,nullptr,nullptr);
                if(!scaler)throw std::bad_alloc();
                std::unique_ptr<SwsContext,decltype(&sws_freeContext)> owned(scaler,sws_freeContext);
                const int matrix=frame->colorspace==AVCOL_SPC_BT709?SWS_CS_ITU709:
                    frame->colorspace==AVCOL_SPC_BT2020_NCL||frame->colorspace==AVCOL_SPC_BT2020_CL?SWS_CS_BT2020:
                    frame->colorspace==AVCOL_SPC_SMPTE240M?SWS_CS_SMPTE240M:
                    frame->colorspace==AVCOL_SPC_UNSPECIFIED&&frame->height>576?SWS_CS_ITU709:SWS_CS_ITU601;
                const int* coefficients=sws_getCoefficients(matrix);
                capture::check(sws_setColorspaceDetails(scaler,coefficients,frame->color_range==AVCOL_RANGE_JPEG,coefficients,1,0,1<<16,1<<16));
                uint8_t* target[]={pixels,nullptr,nullptr,nullptr};const int lines[]={pitch,0,0,0};
                if(sws_scale(scaler,frame->data,frame->linesize,0,frame->height,target,lines)!=height)throw std::runtime_error("Frame conversion failed");
                av_frame_unref(frame.get());return time;
            }
            capture::check(received==AVERROR(EAGAIN)?0:received);
            if(flushing)throw std::runtime_error("Decoder stalled");
            int read;
            do {av_packet_unref(packet.get());if(cancelled())throw std::runtime_error("Clip export cancelled");read=av_read_frame(local.input.ctx,packet.get());}
            while(read>=0&&packet->stream_index!=video);
            if(read==AVERROR_EOF){capture::check(avcodec_send_packet(decoder.ctx,nullptr));flushing=true;}
            else {capture::check(read);capture::check(avcodec_send_packet(decoder.ctx,packet.get()));}
        }
    }
};
// Copy heard PCM unchanged; retain the same time origin used by Decoder::next.
inline void mux(const std::string& encoded,const std::string& source,const std::string& target,const std::string& mode,const std::function<bool()>& cancelled) {
    Local video(encoded),audio(source);
    const int vi=av_find_best_stream(video.input.ctx,AVMEDIA_TYPE_VIDEO,-1,-1,nullptr,0);
    const int ai=av_find_best_stream(audio.input.ctx,AVMEDIA_TYPE_AUDIO,-1,-1,nullptr,0);
    capture::check(vi);capture::check(ai);
    capture::Output output;capture::check(avformat_alloc_output_context2(&output.ctx,nullptr,"matroska",nullptr));
    if(!output.ctx)throw std::bad_alloc();
    auto* vs=avformat_new_stream(output.ctx,nullptr);auto* as=avformat_new_stream(output.ctx,nullptr);
    if(!vs||!as)throw std::bad_alloc();
    auto* vin=video.input.ctx->streams[vi];auto* ain=audio.input.ctx->streams[ai];
    capture::check(avcodec_parameters_copy(vs->codecpar,vin->codecpar));capture::check(avcodec_parameters_copy(as->codecpar,ain->codecpar));
    vs->codecpar->codec_tag=as->codecpar->codec_tag=0;vs->time_base=vin->time_base;as->time_base=ain->time_base;
    av_dict_set(&output.ctx->metadata,"thru3d_mode",mode.c_str(),0);
    av_dict_set(&output.ctx->metadata,"thru3d_pip","composed",0);av_dict_set(&as->metadata,"title","Live audio",0);
    if(auto* mask=av_dict_get(audio.input.ctx->metadata,"thru3d_audio_channel_mask",nullptr,0))
        av_dict_set(&output.ctx->metadata,"thru3d_audio_channel_mask",mask->value,0);
    capture::check(avio_open(&output.ctx->pb,target.c_str(),AVIO_FLAG_WRITE));capture::check(avformat_write_header(output.ctx,nullptr));
    auto vp=capture::packet(),ap=capture::packet();bool hv=false,ha=false,ev=false,ea=false;
    auto read=[&](Local& local,int track,AVPacket* packet,bool& have,bool& ended,int64_t origin) {
        while(!have&&!ended) {
            if(cancelled())throw std::runtime_error("Clip export cancelled");
            const int result=av_read_frame(local.input.ctx,packet);
            if(result==AVERROR_EOF){ended=true;break;}capture::check(result);
            if(packet->stream_index!=track){av_packet_unref(packet);continue;}
            const auto offset=av_rescale_q(origin,AV_TIME_BASE_Q,local.input.ctx->streams[track]->time_base);
            if(packet->pts!=AV_NOPTS_VALUE)packet->pts-=offset;
            if(packet->dts!=AV_NOPTS_VALUE)packet->dts-=offset;
            have=true;
        }
    };
    for(;;) {
        read(video,vi,vp.get(),hv,ev,0);read(audio,ai,ap.get(),ha,ea,audio.input.origin());
        if(!hv&&!ha)break;
        const bool v=hv&&(!ha||capture::micros(vp->dts,vin->time_base)<=capture::micros(ap->dts,ain->time_base));
        auto* packet=v?vp.get():ap.get();auto* in=v?vin:ain;auto* out=v?vs:as;
        av_packet_rescale_ts(packet,in->time_base,out->time_base);packet->stream_index=out->index;packet->pos=-1;
        capture::check(av_interleaved_write_frame(output.ctx,packet));av_packet_unref(packet);
        if(v)hv=false;else ha=false;
    }
    capture::check(av_write_trailer(output.ctx));avio_flush(output.ctx->pb);capture::check(output.ctx->pb->error);
}
}
