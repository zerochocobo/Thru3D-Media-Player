/* Profile 5 has no backwards-compatible base layer. Do not opt other profiles
 * into this renderer: they retain the existing playback/Alpha fast paths. */
#pragma once
#include <libavutil/dovi_meta.h>
#include <libavutil/frame.h>
#include <libavutil/buffer.h>

/* The Profile 5 MediaCodec patch marks IPT_C2 only after attaching the parsed
 * RPU for this output PTS. */
static inline bool quest_dovi_profile5_hw_frame(const AVFrame *frame)
{
    return frame->format == AV_PIX_FMT_MEDIACODEC &&
           frame->colorspace == AVCOL_SPC_IPT_C2;
}

struct quest_dovi_state {
    bool mapped, hw, rpu;
    int vdr_rpu_profile, full_range, disable_residual;
};

static inline struct quest_dovi_state quest_dovi_state(const struct mp_image *image)
{
    struct quest_dovi_state s = {0};
    if (!image)
        return s;
    s.mapped = image->dovi;
    s.hw = image->quest_dovi_profile5_hw;
    for (int n = 0; n < image->num_ff_side_data; n++) {
        const struct mp_ff_side_data *sd = &image->ff_side_data[n];
        if (sd->type != AV_FRAME_DATA_DOVI_METADATA)
            continue;
        const AVDOVIMetadata *md = (const void *)sd->buf->data;
        const AVDOVIRpuDataHeader *h = av_dovi_get_header(md);
        s.rpu = true;
        s.vdr_rpu_profile = h->vdr_rpu_profile;
        s.full_range = h->bl_video_full_range_flag;
        s.disable_residual = h->disable_residual_flag;
        break;
    }
    return s;
}

static inline bool quest_dovi_state_profile5(struct quest_dovi_state s)
{
    return s.mapped && (s.hw || (s.rpu && s.vdr_rpu_profile == 0 &&
                                 s.full_range && s.disable_residual));
}

static inline bool quest_dovi_profile5(const struct mp_image *image)
{
    return quest_dovi_state_profile5(quest_dovi_state(image));
}

/* 0 for frames without Dolby metadata; a renderer logs each change, so a
 * rejected Profile 5 frame shows which link (RPU, mapping, marker) it lost. */
static inline int quest_dovi_signature(struct quest_dovi_state s)
{
    if (!s.mapped && !s.hw && !s.rpu)
        return 0;
    return 1 | (s.mapped << 1) | (s.hw << 2) | (s.rpu << 3) | (!!s.full_range << 4) |
           (!!s.disable_residual << 5) | ((s.vdr_rpu_profile & 0xff) << 8);
}
