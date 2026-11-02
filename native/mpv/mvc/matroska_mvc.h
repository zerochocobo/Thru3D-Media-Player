/* Included by the pinned Matroska demuxer after its private track types. */
#include "libavcodec/mvc_config.h"

static int thru3d_matroska_mvc(AVFormatContext *s, AVStream *st, MatroskaTrack *track)
{
    AVCodecParameters *par = st->codecpar;
    const uint8_t *mvc = NULL;
    size_t mvc_size = 0;
    ThruMvcConfig config;
    if (par->codec_id != AV_CODEC_ID_H264) return 0;
    const MatroskaBlockAdditionMapping *maps = track->block_addition_mappings.elem;
    for (int i = 0; i < track->block_addition_mappings.nb_elem; ++i) {
        if (maps[i].type != MKBETAG('m','v','c','C')) continue;
        if (mvc || !maps[i].extradata.size) return AVERROR_INVALIDDATA;
        mvc = maps[i].extradata.data;
        mvc_size = maps[i].extradata.size;
    }
    /* Leave ordinary AVC untouched, including non-avcC legacy variants. */
    if (!mvc && (!par->extradata_size || par->extradata[0] != 1)) return 0;
    int ret = thru_mvc_config(par->extradata, par->extradata_size, mvc, mvc_size,
                             track->video.stereo_mode == 14, &config);
    if (ret <= 0) {
        /* A malformed ordinary AVC header remains the ordinary decoder's job;
         * an explicit MVC declaration must never silently become 2D. */
        if (config.mvc || track->video.stereo_mode == 13 || track->video.stereo_mode == 14)
            return ret < 0 ? AVERROR_INVALIDDATA : 0;
        return 0;
    }
    if (par->width <= 0 || par->width > 1920 || par->height <= 0 || par->height > 1080 ||
        par->field_order == AV_FIELD_TT || par->field_order == AV_FIELD_BB ||
        par->field_order == AV_FIELD_TB || par->field_order == AV_FIELD_BT ||
        (track->video.stereo_mode && track->video.stereo_mode != 13 && track->video.stereo_mode != 14))
        return AVERROR_PATCHWELCOME;
    size_t size = 16 + config.avc_size + config.mvc_size;
    uint8_t *extra = av_mallocz(size + AV_INPUT_BUFFER_PADDING_SIZE);
    if (!extra) return AVERROR(ENOMEM);
    memcpy(extra, "T3MV", 4); extra[4] = 1; extra[5] = config.base_right;
    thru_mvc_put32(extra + 8, config.avc_size);
    thru_mvc_put32(extra + 12, config.mvc_size);
    memcpy(extra + 16, config.avc, config.avc_size);
    memcpy(extra + 16 + config.avc_size, config.mvc, config.mvc_size);
    av_freep(&par->extradata); par->extradata = extra; par->extradata_size = size;
    par->codec_id = AV_CODEC_ID_H264_MVC; par->codec_tag = 0;
    par->width *= 2; par->format = AV_PIX_FMT_YUV420P;
    par->sample_aspect_ratio = st->sample_aspect_ratio = (AVRational){1, 1};
    ffstream(st)->need_parsing = AVSTREAM_PARSE_NONE;
    AVPacketSideData *sd = (AVPacketSideData *)av_packet_side_data_get(par->coded_side_data,
                                                par->nb_coded_side_data, AV_PKT_DATA_STEREO3D);
    if (!sd) sd = av_packet_side_data_new(&par->coded_side_data, &par->nb_coded_side_data,
                                         AV_PKT_DATA_STEREO3D, sizeof(AVStereo3D), 0);
    if (!sd || sd->size < sizeof(AVStereo3D)) return AVERROR(ENOMEM);
    *(AVStereo3D *)sd->data = (AVStereo3D){.type = AV_STEREO3D_SIDEBYSIDE, .view = AV_STEREO3D_VIEW_PACKED};
    av_dict_set(&st->metadata, "stereo_mode", "left_right", 0);
    av_dict_set(&st->metadata, "thru3d_mvc_mkv", "1", 0);
    av_log(s, AV_LOG_INFO, "Thru3D MVC MKV: %dx%d full-SBS, base eye %s\n",
           par->width, par->height, config.base_right ? "right" : "left");
    return 0;
}
