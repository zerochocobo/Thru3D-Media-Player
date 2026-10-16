"""Reproducible Apple MV-HEVC additions to the locked MPV decoder."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]


def apply_mpv_spatial(edited, replace):
    edited['video/decode/quest_spatial_video.h'] = (
        ROOT / 'native/mpv/spatial/quest_spatial_video.h').read_text(encoding='utf-8')
    edited['video/quest_spatial_metadata.h'] = (
        ROOT / 'native/mpv/spatial/quest_spatial_metadata.h').read_text(encoding='utf-8')
    p = 'video/decode/vd_lavc.c'
    s = edited[p]
    s = replace(s, '#include "options/m_option.h"\n',
                '#include "options/m_option.h"\n#include "quest_spatial_video.h"\n')
    s = replace(s, '    bool fast;\n', '    bool fast;\n    bool spatial_video;\n')
    s = replace(s, '        {"vd-lavc-fast", OPT_BOOL(fast)},\n',
                '        {"vd-lavc-fast", OPT_BOOL(fast)},\n'
                '        {"vd-lavc-spatial-video", OPT_BOOL(spatial_video)},\n')
    s = replace(s, '    AVFrame *pic;\n', '    AVFrame *pic;\n'
                '    bool quest_spatial;\n    struct quest_spatial_pair quest_pair;\n')
    s = replace(s, '    select_and_set_hwdec(vd);\n\n    bool use_hwdec',
                '    m_config_cache_update(ctx->opts_cache);\n'
                '    ctx->quest_spatial = ctx->opts->spatial_video &&\n'
                '        quest_spatial_candidate(ctx->codec->lav_codecpar);\n'
                '    // MediaCodec exposes only the base layer, even when it succeeds.\n'
                '    select_and_set_hwdec(vd);\n\n    bool use_hwdec')
    s = replace(s, '        } else if (ctx->force_swdec) {\n',
                '        } else if (ctx->force_swdec || ctx->quest_spatial) {\n')
    s = replace(s, '    /* open it */\n',
                '    if (ctx->quest_spatial &&\n'
                '        av_opt_set(avctx, "view_ids", "-1", AV_OPT_SEARCH_CHILDREN) < 0)\n'
                '        goto error;\n\n    /* open it */\n')
    s = replace(s, '    ctx->flushing = false;\n',
                '    quest_spatial_clear(&ctx->quest_pair);\n    ctx->flushing = false;\n')
    s = replace(s, '    mp_codec_info_from_av(avctx, ctx->codec);\n',
                '    mp_codec_info_from_av(avctx, ctx->codec);\n'
                '    if (ctx->quest_spatial) {\n'
                '        int joined = quest_spatial_join(&ctx->quest_pair, ctx->pic);\n'
                '        if (joined < 0) {\n'
                '            MP_ERR(vd, "Invalid spatial video eye pair.\\n");\n'
                '            av_frame_unref(ctx->pic);\n'
                '            quest_spatial_clear(&ctx->quest_pair);\n'
                '            mp_filter_internal_mark_failed(vd);\n'
                '            return joined;\n'
                '        }\n'
                '        if (!joined) return 0; // drain the other view before more input\n'
                '    }\n')
    s = replace(s, '    if (mpi->imgfmt == IMGFMT_CUDA',
                '    mpi->params.quest_spatial_video = ctx->quest_spatial;\n'
                '    if (ctx->quest_spatial) mpi->params.stereo3d = MP_STEREO3D_SBS2L;\n\n'
                '    if (mpi->imgfmt == IMGFMT_CUDA')
    edited[p] = s
    p = 'video/mp_image.h'
    edited[p] = replace(edited[p], '    bool force_window;',
                        '    bool quest_spatial_video; // decoded, full-resolution left/right pair\n'
                        '    bool force_window;')
    p = 'video/mp_image.c'
    edited[p] = replace(edited[p], '    dst->params.stereo3d = src->params.stereo3d;\n',
                        '    dst->params.stereo3d = src->params.stereo3d;\n'
                        '    dst->params.quest_spatial_video = src->params.quest_spatial_video;\n')
    edited[p] = replace(edited[p], '           p1->stereo3d == p2->stereo3d &&\n',
                        '           p1->stereo3d == p2->stereo3d &&\n'
                        '           p1->quest_spatial_video == p2->quest_spatial_video &&\n')
    edited[p] = replace(edited[p], '        dst->params.stereo3d = p->stereo3d;\n',
                        '        dst->params.stereo3d = p->stereo3d;\n'
                        '        dst->params.quest_spatial_video = p->quest_spatial_video;\n')
    p = 'filters/f_decoder_wrapper.c'
    edited[p] = replace(edited[p], '    m.stereo3d = p->codec->stereo_mode;\n',
                        '    m.stereo3d = m.quest_spatial_video ? MP_STEREO3D_SBS2L : p->codec->stereo_mode;\n')
    p = 'video/out/vo_libmpv.c'
    edited[p] = replace(edited[p], '#include "include/mpv/quest_frame.h"\n',
                        '#include "include/mpv/quest_frame.h"\n#include "video/quest_spatial_metadata.h"\n')
    edited[p] = replace(edited[p], '        quest->render_sequence = ++ctx->quest_render_sequence;\n',
                        '        quest->render_sequence = ++ctx->quest_render_sequence;\n'
                        '        quest_mpv_spatial_metadata *spatial = get_mpv_render_param(\n'
                        '            params, MPV_RENDER_PARAM_QUEST_SPATIAL_METADATA, NULL);\n'
                        '        if (spatial && spatial->struct_size != sizeof(*spatial)) spatial = NULL;\n'
                        '        if (spatial) quest_spatial_metadata_read(spatial, NULL);\n')
    edited[p] = replace(edited[p], '            quest->mpv_image_format = image->imgfmt;\n',
                        '            quest->mpv_image_format = image->imgfmt;\n'
                        '            if (image->params.quest_spatial_video) {\n'
                        '                quest->flags |= QUEST_MPV_SPATIAL_VIDEO;\n'
                        '                for (int n = 0; spatial && n < image->num_ff_side_data; n++) {\n'
                        '                    const struct mp_ff_side_data *sd = &image->ff_side_data[n];\n'
                        '                    if (sd->type == AV_FRAME_DATA_STEREO3D && sd->buf->size >= sizeof(AVStereo3D)) {\n'
                        '                        quest_spatial_metadata_read(spatial, (const AVStereo3D *)sd->buf->data);\n'
                        '                        break;\n'
                        '                    }\n'
                        '                }\n'
                        '            }\n')
