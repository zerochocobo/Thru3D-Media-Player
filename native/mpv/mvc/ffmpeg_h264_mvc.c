/* Thru3D MVC adapter, LGPL-2.1-or-later. edge264-mvc retains BSD-3-Clause. */
#include <errno.h>
#include <stdlib.h>
#include "libavutil/imgutils.h"
#include "libavutil/mem.h"
#include "libavutil/stereo3d.h"
#include "libavutil/version.h"
#include "avcodec.h"
#include "codec_internal.h"
#include "decode.h"
#include "internal.h"
#include "edge264mvc/edge264mvc.h"

typedef struct MvcDecoder {
    Edge264MvcDecoder *decoder;
    AVPacket *packet;
    size_t next;
    int draining, base_right;
    int clip, pending_clip, boundary_draining;
    int64_t start, end, pending_start, pending_end;
    uint64_t pairs;
} MvcDecoder;

static av_cold int mvc_init(AVCodecContext *avctx)
{
    MvcDecoder *s = avctx->priv_data;
    Edge264MvcSettings settings;
    edge264mvc_default_settings(&settings);
    settings.n_threads = 4;
    settings.max_frame_pixels = 4096 * 2160;
    if (edge264mvc_open(&s->decoder, &settings) != EDGE264MVC_OK)
        return AVERROR(ENOMEM);
    s->packet = av_packet_alloc();
    if (!s->packet) {
        edge264mvc_close(&s->decoder);
        return AVERROR(ENOMEM);
    }
    s->base_right = avctx->extradata_size == 1 && avctx->extradata[0] == 1;
    s->clip = -1;
    s->end = INT64_MAX;
    avctx->pix_fmt = AV_PIX_FMT_YUV420P;
    avctx->color_range = AVCOL_RANGE_MPEG;
    avctx->colorspace = AVCOL_SPC_BT709;
    avctx->color_primaries = AVCOL_PRI_BT709;
    avctx->color_trc = AVCOL_TRC_BT709;
    av_log(avctx, AV_LOG_INFO, "Thru3D MVC: edge264-mvc %s, 4 workers, base eye %s\n",
           edge264mvc_version(), s->base_right ? "right" : "left");
    return 0;
}

static void mvc_flush(AVCodecContext *avctx)
{
    MvcDecoder *s = avctx->priv_data;
    edge264mvc_flush(s->decoder);
    av_packet_unref(s->packet);
    s->next = 0;
    s->draining = 0;
    s->clip = -1;
    s->boundary_draining = 0;
    s->start = INT64_MIN; s->end = INT64_MAX;
}

static av_cold int mvc_close(AVCodecContext *avctx)
{
    MvcDecoder *s = avctx->priv_data;
    av_packet_free(&s->packet);
    edge264mvc_close(&s->decoder);
    return 0;
}

static int mvc_copy(AVCodecContext *avctx, AVFrame *frame, const Edge264MvcFrame *pair)
{
    MvcDecoder *s = avctx->priv_data;
    AVStereo3D *stereo;
    int ret;
    if (!pair->views[0].planes[0] || !pair->views[1].planes[0] ||
        pair->views[0].pts != pair->views[1].pts || pair->bit_depth_Y != 8 ||
        (pair->views[0].flags | pair->views[1].flags) & EDGE264MVC_VIEW_CONCEALED) {
        av_log(avctx, AV_LOG_ERROR, "MVC picture is missing a matched, intact view: pts %"PRId64"/%"PRId64", flags %x/%x\n",
               pair->views[0].pts, pair->views[1].pts, pair->views[0].flags, pair->views[1].flags);
        return AVERROR_INVALIDDATA;
    }
    ret = ff_set_dimensions(avctx, pair->width_Y * 2, pair->height_Y);
    if (ret < 0)
        return ret;
    frame->format = AV_PIX_FMT_YUV420P;
    frame->width = avctx->width;
    frame->height = avctx->height;
    if ((ret = ff_get_buffer(avctx, frame, 0)) < 0)
        return ret;
    for (int plane = 0; plane < 3; plane++) {
        int w = plane ? pair->width_C : pair->width_Y;
        int h = plane ? pair->height_C : pair->height_Y;
        int stride = plane ? pair->stride_C : pair->stride_Y;
        for (int y = 0; y < h; y++) {
            uint8_t *out = frame->data[plane] + (ptrdiff_t)y * frame->linesize[plane];
            memcpy(out, pair->views[s->base_right].planes[plane] + (ptrdiff_t)y * stride, w);
            memcpy(out + w, pair->views[!s->base_right].planes[plane] + (ptrdiff_t)y * stride, w);
        }
    }
    frame->pts = pair->views[0].pts;
    frame->pkt_dts = pair->views[0].user_data;
    frame->sample_aspect_ratio = (AVRational){1, 1};
    frame->color_range = AVCOL_RANGE_MPEG;
    frame->colorspace = AVCOL_SPC_BT709;
    frame->color_primaries = AVCOL_PRI_BT709;
    frame->color_trc = AVCOL_TRC_BT709;
    if (pair->views[0].flags & EDGE264MVC_VIEW_IDR)
        frame->flags |= AV_FRAME_FLAG_KEY;
    AVFrameSideData *stereo_data = av_frame_get_side_data(frame, AV_FRAME_DATA_STEREO3D);
    stereo = stereo_data ? (AVStereo3D *)stereo_data->data : av_stereo3d_create_side_data(frame);
    if (!stereo)
        return AVERROR(ENOMEM);
    stereo->type = AV_STEREO3D_SIDEBYSIDE;
    stereo->view = AV_STEREO3D_VIEW_PACKED;
    s->pairs++;
    if (s->pairs == 1 || (frame->flags & AV_FRAME_FLAG_KEY))
        av_log(avctx, AV_LOG_VERBOSE, "MVC pair %"PRIu64" pts=%"PRId64" full-SBS %dx%d\n",
               s->pairs, frame->pts, frame->width, frame->height);
    return 0;
}

static int mvc_receive(AVCodecContext *avctx, AVFrame *frame)
{
    MvcDecoder *s = avctx->priv_data;
    for (;;) {
        Edge264MvcFrame pair;
        int result = edge264mvc_receive_frame(s->decoder, &pair);
        if (result == EDGE264MVC_OK) {
            if (pair.views[0].pts < s->start || pair.views[0].pts >= s->end) {
                edge264mvc_release_frame(s->decoder, &pair);
                continue;
            }
            int ret = mvc_copy(avctx, frame, &pair);
            edge264mvc_release_frame(s->decoder, &pair);
            return ret;
        }
        if (result == EDGE264MVC_END && s->boundary_draining) {
            /* Preserve all reordered frames at the old clip's tail before
               resetting its references. The next clip's first packet is held. */
            edge264mvc_flush(s->decoder);
            s->boundary_draining = 0;
            s->clip = s->pending_clip;
            s->start = s->pending_start; s->end = s->pending_end;
            continue;
        }
        if (result == EDGE264MVC_END)
            return AVERROR_EOF;
        if (result != EDGE264MVC_AGAIN)
            return AVERROR_EXTERNAL;
        if (!s->packet->size) {
            int ret = ff_decode_get_packet(avctx, s->packet);
            if (ret == AVERROR_EOF) {
                if (s->draining)
                    return AVERROR_EOF;
                edge264mvc_send_end(s->decoder);
                s->draining = 1;
                continue;
            }
            if (ret < 0)
                return ret;
            s->next = 0;
            size_t bytes = 0;
            const uint8_t *data = av_packet_get_side_data(s->packet, AV_PKT_DATA_STRINGS_METADATA, &bytes);
            AVDictionary *tag = NULL;
            if (data && av_packet_unpack_dictionary(data, bytes, &tag) < 0) {
                av_dict_free(&tag); return AVERROR_INVALIDDATA;
            }
            const AVDictionaryEntry *entry = av_dict_get(tag, "thru3d_mvc_clip", NULL, 0);
            int clip = s->clip < 0 ? 0 : s->clip;
            int64_t start = s->start, end_time = s->end;
            if (entry) {
                char *end;
                long value = strtol(entry->value, &end, 10);
                if (end == entry->value || *end || value < 0 || value >= 4096) { av_dict_free(&tag); return AVERROR_INVALIDDATA; }
                clip = value;
                const AVDictionaryEntry *begin = av_dict_get(tag, "thru3d_mvc_start", NULL, 0);
                const AVDictionaryEntry *finish = av_dict_get(tag, "thru3d_mvc_end", NULL, 0);
                if (!begin || !finish) { av_dict_free(&tag); return AVERROR_INVALIDDATA; }
                start = strtoll(begin->value, &end, 10);
                if (end == begin->value || *end) { av_dict_free(&tag); return AVERROR_INVALIDDATA; }
                end_time = strtoll(finish->value, &end, 10);
                if (end == finish->value || *end || end_time <= start) { av_dict_free(&tag); return AVERROR_INVALIDDATA; }
            }
            av_dict_free(&tag);
            if (s->clip >= 0 && clip != s->clip) {
                if (edge264mvc_send_end(s->decoder) != EDGE264MVC_OK) return AVERROR_EXTERNAL;
                s->pending_clip = clip;
                s->pending_start = start; s->pending_end = end_time;
                s->boundary_draining = 1;
                continue;
            }
            s->clip = clip;
            s->start = start; s->end = end_time;
        }
        if (!s->packet->size)
            return AVERROR(EAGAIN);
        size_t offset = edge264mvc_find_start_code(s->packet->data + s->next, s->packet->size - s->next);
        size_t begin = s->next + offset;
        if (begin >= s->packet->size) {
            av_packet_unref(s->packet);
            continue;
        }
        begin += 3;
        size_t length = edge264mvc_find_start_code(s->packet->data + begin, s->packet->size - begin);
        size_t end = begin + length;
        /* The zero preceding a four-byte start code is Annex B trailing_zero_8bits. */
        while (end > begin && s->packet->data[end - 1] == 0)
            end--;
        if (end == begin) {
            s->next = begin + length;
            continue;
        }
        /* SSIF stores per-view sequence terminators. A base-view EOS can
           precede the last dependent NAL in the same paired packet; letting
           it flush the decoder here would publish a one-eyed final frame.
           The paired clip marker / FFmpeg drain terminates both views. */
        int nal_type = s->packet->data[begin] & 31;
        if (nal_type == 10 || nal_type == 11) {
            s->next = begin + length;
            continue;
        }
        result = edge264mvc_send_nal(s->decoder, s->packet->data + begin, end - begin,
                                    s->packet->pts, s->packet->dts);
        if (result == EDGE264MVC_AGAIN)
            continue;
        if (result == EDGE264MVC_CORRUPT ||
            (result == EDGE264MVC_UNSUPPORTED && (s->packet->data[begin] & 31) < 24))
            return AVERROR_INVALIDDATA;
        if (result != EDGE264MVC_OK && result != EDGE264MVC_UNSUPPORTED)
            return AVERROR_EXTERNAL;
        s->next = begin + length;
        if (s->next >= s->packet->size)
            av_packet_unref(s->packet);
    }
}

const FFCodec ff_h264_mvc_decoder = {
    .p.name = "h264_mvc",
    CODEC_LONG_NAME("H.264 MVC stereo via edge264-mvc"),
    .p.type = AVMEDIA_TYPE_VIDEO,
    .p.id = AV_CODEC_ID_H264_MVC,
    .priv_data_size = sizeof(MvcDecoder),
    .init = mvc_init,
    .close = mvc_close,
    .flush = mvc_flush,
    FF_CODEC_RECEIVE_FRAME_CB(mvc_receive),
    .p.capabilities = AV_CODEC_CAP_DELAY | AV_CODEC_CAP_OTHER_THREADS,
    .caps_internal = FF_CODEC_CAP_SETS_FRAME_PROPS,
};
