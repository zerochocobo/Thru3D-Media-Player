/* Host-only real DVD navigation/decode probe. Commands on stdin: kind x y.
 * Writes the latest decoded RGB frame and the menu plane for visual inspection.
 * Never opens a headset or modifies media. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <stdatomic.h>
#include <inttypes.h>
#include <poll.h>
#include "libavformat/avformat.h"
#include "libavcodec/avcodec.h"
#include "libswscale/swscale.h"
#include "libavutil/time.h"
extern int avformat_thru3d_bd_titles(const char *,int,int *,int *,int64_t *,int *,int *,char *,int);
extern int avformat_thru3d_bd_menu_state(char *,int);
extern int avformat_thru3d_bd_menu_overlay(uint64_t,uint8_t *,int,int *);
extern int avformat_thru3d_bd_menu_input(int,int,int);
static atomic_int stop, frames, failed;
static const char *source, *directory;
static int64_t deadline;
static int interrupt(void *unused) { return atomic_load(&stop) || av_gettime_relative()>deadline; }

static void save_frame(AVFrame *frame)
{
    struct SwsContext *sws=sws_getContext(frame->width,frame->height,frame->format,
        frame->width,frame->height,AV_PIX_FMT_RGB24,SWS_POINT,NULL,NULL,NULL);
    uint8_t *rgb=av_malloc(frame->width*frame->height*3);
    uint8_t *dst[]={rgb}; int stride[]={frame->width*3};
    if(sws && rgb) {
        sws_scale(sws,(const uint8_t *const *)frame->data,frame->linesize,0,frame->height,dst,stride);
        char path[1024]; snprintf(path,sizeof(path),"%s/frame.ppm",directory);
        FILE *f=fopen(path,"wb");
        if(f) { fprintf(f,"P6\n%d %d\n255\n",frame->width,frame->height); fwrite(rgb,3,frame->width*frame->height,f); fclose(f); }
    }
    av_free(rgb); sws_freeContext(sws);
}

static void *decode(void *unused)
{
    AVFormatContext *ctx=avformat_alloc_context();
    ctx->interrupt_callback=(AVIOInterruptCB){interrupt,NULL};
    AVDictionary *options=NULL; av_dict_set(&options,"menu","1",0);
    int ret=avformat_open_input(&ctx,source,av_find_input_format("bd_mvc"),&options);
    av_dict_free(&options);
    if(ret<0) { fprintf(stderr,"menu open %d\n",ret); atomic_store(&failed,1); return NULL; }
    AVCodecContext *decoder=NULL;
    AVPacket *packet=av_packet_alloc(); AVFrame *frame=av_frame_alloc();
    int64_t clock_start=av_gettime_relative(), first_pts=AV_NOPTS_VALUE;
    while(!interrupt(NULL)) {
        ret=av_read_frame(ctx,packet);
        if(ret<0) {
            if(ret!=AVERROR_EOF && !interrupt(NULL)) atomic_store(&failed,1);
            break;
        }
        AVStream *stream=ctx->streams[packet->stream_index];
        /* Pace by VIDEO only, like a demux queue waiting for its next picture.
         * This catches still menus that otherwise consume all audio ahead. */
        if(packet->pts!=AV_NOPTS_VALUE && stream->codecpar->codec_type==AVMEDIA_TYPE_VIDEO) {
            int64_t pts=av_rescale_q(packet->pts,stream->time_base,AV_TIME_BASE_Q);
            if(first_pts==AV_NOPTS_VALUE) first_pts=pts;
            int64_t wait=clock_start+pts-first_pts-av_gettime_relative();
            while(wait>0 && !interrupt(NULL)) { av_usleep(FFMIN(wait,10000)); wait=clock_start+pts-first_pts-av_gettime_relative(); }
        }
        if(stream->codecpar->codec_type==AVMEDIA_TYPE_VIDEO) {
            fprintf(stderr,"video packet bytes %d pts %"PRId64"\n",packet->size,packet->pts);
            if(!decoder) {
                decoder=avcodec_alloc_context3(avcodec_find_decoder(stream->codecpar->codec_id));
                avcodec_parameters_to_context(decoder,stream->codecpar);
                decoder->pkt_timebase=stream->time_base;
                if(avcodec_open2(decoder,NULL,NULL)<0) { atomic_store(&failed,1); break; }
            }
            if(avcodec_send_packet(decoder,packet)>=0) {
                int decoded;
                while((decoded=avcodec_receive_frame(decoder,frame))>=0) {
                    atomic_fetch_add(&frames,1); save_frame(frame); av_frame_unref(frame);
                }
                if(decoded!=AVERROR(EAGAIN) && decoded!=AVERROR_EOF) atomic_store(&failed,1);
            } else atomic_store(&failed,1);
        }
        av_packet_unref(packet);
    }
    fprintf(stderr,"menu read exit %d frames %d failed %d\n",ret,atomic_load(&frames),atomic_load(&failed));
    av_packet_free(&packet); av_frame_free(&frame); avcodec_free_context(&decoder); avformat_close_input(&ctx);
    return NULL;
}

int main(int argc,char **argv)
{
    if(argc<2) return 2;
    av_log_set_level(getenv("DVD_PROBE_DEBUG") ? AV_LOG_DEBUG : AV_LOG_WARNING);
    source=argv[1]; directory=argc>2?argv[2]:".";
    int w=0,h=0,mvc=0,title=-1; int64_t duration=0; char titles[32768];
    int ret=avformat_thru3d_bd_titles(source,-1,&w,&h,&duration,&mvc,&title,titles,sizeof(titles));
    if(ret<0) { fprintf(stderr,"probe %d\n",ret); return 3; }
    printf("{\"width\":%d,\"height\":%d,\"selected\":%d,\"duration_us\":%"PRId64",\"disc\":%s}\n",w,h,title,duration,titles); fflush(stdout);
    if(argc<3) return 0;
    deadline=av_gettime_relative()+90000000;
    pthread_t worker; pthread_create(&worker,NULL,decode,NULL);
    char previous[1024]="";
    while(!interrupt(NULL) && !atomic_load(&failed)) {
        char state[1024]; avformat_thru3d_bd_menu_state(state,sizeof(state));
        if(strcmp(previous,state)) {
            printf("%s\n",state); fflush(stdout); strcpy(previous,state);
            char *version=strstr(state,"\"version\":");
            if(version) {
                uint64_t v=strtoull(version+10,NULL,10); int rect[6]={0};
                uint8_t *pixels=av_malloc(720*576*4);
                int bytes=avformat_thru3d_bd_menu_overlay(v,pixels,720*576*4,rect);
                if(bytes>0) {
                    char path[1024]; snprintf(path,sizeof(path),"%s/overlay.rgba",directory);
                    FILE *f=fopen(path,"wb"); if(f) { fwrite(pixels,1,bytes,f); fclose(f); }
                    snprintf(path,sizeof(path),"%s/overlay.json",directory);
                    f=fopen(path,"w"); if(f) { fprintf(f,"[%d,%d,%d,%d,%d,%d]",rect[0],rect[1],rect[2],rect[3],rect[4],rect[5]); fclose(f); }
                }
                av_free(pixels);
            }
        }
        struct pollfd input={.fd=0,.events=POLLIN};
        if(poll(&input,1,80)>0 && (input.revents&POLLIN)) {
            char line[128];
            if(fgets(line,sizeof(line),stdin)) {
                int kind,x,y;
                if(sscanf(line,"%d %d %d",&kind,&x,&y)==3) {
                    if(kind<0) { atomic_store(&stop,1); break; }
                    printf("{\"input\":%d}\n",avformat_thru3d_bd_menu_input(kind,x,y)); fflush(stdout);
                }
            }
        }
    }
    atomic_store(&stop,1); pthread_join(worker,NULL);
    return atomic_load(&failed) || !atomic_load(&frames);
}
