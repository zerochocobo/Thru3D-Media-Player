/* Production ISO demux/MVC decode, independent AVC base-eye comparison and audio.
 * Writes technical counters only; never stores decoded pictures or source media. */
#include <inttypes.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "libavformat/avformat.h"
#include "libavcodec/avcodec.h"
#include "libavutil/error.h"
#include "libavutil/stereo3d.h"
#include "libavutil/time.h"

#define QUEUE 64
typedef struct Stats {
    double start, end, first, last, max_gap, audio_end, audio_gap;
    int frames, compared, different, done[3], count[2], base_eye;
    int verify_preroll, preroll_compared;
    int64_t samples;
    int64_t ref_start, ref_end;
    uint64_t eyes[2], clip_mask;
    AVFrame *queued[2][QUEUE];
} Stats;

static int compare(Stats *s)
{
    while (s->count[0] && s->count[1]) {
        AVFrame *stereo = s->queued[0][0], *base = s->queued[1][0];
        if (stereo->pts != base->pts || base->width * 2 != stereo->width || base->height != stereo->height ||
            stereo->format != AV_PIX_FMT_YUV420P || base->format != AV_PIX_FMT_YUV420P) {
            fprintf(stderr, "Independent base PTS/format mismatch: %"PRId64" / %"PRId64"\n", stereo->pts, base->pts);
            return AVERROR_INVALIDDATA;
        }
        AVFrameSideData *side = av_frame_get_side_data(stereo, AV_FRAME_DATA_STEREO3D);
        if (!side || ((AVStereo3D *)side->data)->type != AV_STEREO3D_SIDEBYSIDE) return AVERROR_INVALIDDATA;
        uint64_t hashes[2] = {1469598103934665603ULL, 1469598103934665603ULL};
        for (int p = 0; p < 3; p++) {
            int w = p ? base->width / 2 : base->width;
            int h = p ? base->height / 2 : base->height;
            for (int y = 0; y < h; y++) {
                const uint8_t *row = stereo->data[p] + (ptrdiff_t)y * stereo->linesize[p];
                if (memcmp(row + s->base_eye * w, base->data[p] + (ptrdiff_t)y * base->linesize[p], w)) {
                    fprintf(stderr, "Independent base pixels differ at PTS %"PRId64", plane %d row %d\n", base->pts, p, y);
                    return AVERROR_INVALIDDATA;
                }
                if (!(y % 17)) for (int x = 0; x < w; x += 19) for (int eye = 0; eye < 2; eye++) {
                    hashes[eye] ^= row[eye * w + x]; hashes[eye] *= 1099511628211ULL;
                }
            }
        }
        if (stereo->pts / 90000. < s->start - 0.000001) {
            s->preroll_compared++;
        } else {
            for (int eye = 0; eye < 2; eye++) {
                s->eyes[eye] ^= hashes[eye] ^ (uint64_t)stereo->pts;
                s->eyes[eye] *= 1099511628211ULL;
            }
            s->different += hashes[0] != hashes[1];
            s->compared++;
        }
        for (int eye = 0; eye < 2; eye++) {
            av_frame_free(&s->queued[eye][0]);
            memmove(s->queued[eye], s->queued[eye] + 1, --s->count[eye] * sizeof(AVFrame *));
        }
    }
    return 0;
}

static int receive(AVCodecContext *codec, AVFrame *frame, int which, Stats *s)
{
    int ret;
    while ((ret = avcodec_receive_frame(codec, frame)) == 0) {
        if (frame->pts == AV_NOPTS_VALUE || frame->flags & AV_FRAME_FLAG_CORRUPT) return AVERROR_INVALIDDATA;
        double pts = frame->pts / 90000.;
        if (which == 2 && (frame->pts < s->ref_start || frame->pts >= s->ref_end)) {
            av_frame_unref(frame); continue;
        }
        if (pts >= s->end - 0.000001) s->done[which] = 1;
        if ((pts >= s->start - 0.000001 || (s->verify_preroll && which != 1)) && pts < s->end - 0.000001) {
            if (which == 1) {
                if (s->audio_end > 0) s->audio_gap = fmax(s->audio_gap, fabs(pts - s->audio_end));
                s->samples += frame->nb_samples;
                s->audio_end = pts + (double)frame->nb_samples / frame->sample_rate;
            } else {
                int eye = which == 0 ? 0 : 1;
                if (which == 0 && pts >= s->start - 0.000001) {
                    if (s->frames && pts <= s->last) return AVERROR_INVALIDDATA;
                    if (!s->frames) s->first = pts;
                    else s->max_gap = fmax(s->max_gap, pts - s->last);
                    s->last = pts; s->frames++;
                    if (!(s->frames % 1000)) fprintf(stderr, "Decoded/verified %d pairs, PTS %.3f\n", s->frames, pts);
                }
                if (s->count[eye] >= QUEUE) return AVERROR(ENOBUFS);
                s->queued[eye][s->count[eye]++] = av_frame_clone(frame);
                if (!s->queued[eye][s->count[eye]-1]) return AVERROR(ENOMEM);
                if ((ret = compare(s)) < 0) return ret;
            }
        }
        av_frame_unref(frame);
    }
    return ret == AVERROR(EAGAIN) || ret == AVERROR_EOF ? 0 : ret;
}

static int send(AVCodecContext *codec, const AVPacket *packet, AVFrame *frame, int which, Stats *s)
{
    int ret = avcodec_send_packet(codec, packet);
    if (ret == AVERROR(EAGAIN)) {
        if ((ret = receive(codec, frame, which, s)) < 0) return ret;
        ret = avcodec_send_packet(codec, packet);
    }
    return ret < 0 ? ret : receive(codec, frame, which, s);
}

static int packet_clip(const AVPacket *packet, int64_t *start, int64_t *end)
{
    size_t size;
    const uint8_t *data = av_packet_get_side_data(packet, AV_PKT_DATA_STRINGS_METADATA, &size);
    AVDictionary *tag = NULL;
    if (data && av_packet_unpack_dictionary(data, size, &tag) < 0) return -2;
    const AVDictionaryEntry *entry = av_dict_get(tag, "thru3d_mvc_clip", NULL, 0);
    int clip = entry ? atoi(entry->value) : -1;
    if (entry) {
        const AVDictionaryEntry *a = av_dict_get(tag, "thru3d_mvc_start", NULL, 0);
        const AVDictionaryEntry *b = av_dict_get(tag, "thru3d_mvc_end", NULL, 0);
        if (!a || !b) { av_dict_free(&tag); return -2; }
        *start = strtoll(a->value, NULL, 10); *end = strtoll(b->value, NULL, 10);
    }
    av_dict_free(&tag);
    return clip;
}

/* The independent FFmpeg H.264 decoder receives only ordinary AVC NALs,
   excluding MVC prefix/subset/dependent NALs. It shares no edge264 state. */
static int unsigned_golomb(const uint8_t *data, int bytes, int *bit)
{
    int zeros = 0, value = 0;
    while (*bit < bytes * 8 && !(data[*bit / 8] >> (7 - *bit % 8) & 1)) {
        (*bit)++;
        if (++zeros > 8) return -1;
    }
    if (*bit + zeros >= bytes * 8) return -1;
    (*bit)++;
    for (int n = 0; n < zeros; n++, (*bit)++) value = value * 2 + (data[*bit / 8] >> (7 - *bit % 8) & 1);
    return (1 << zeros) - 1 + value;
}

static int base_parameter(const uint8_t *nal, int bytes, uint32_t *sps)
{
    uint8_t rbsp[32];
    int size = 0, zeros = 0, type = nal[0] & 31;
    for (int n = 1; n < bytes && size < (int)sizeof(rbsp); n++) {
        if (zeros == 2 && nal[n] == 3) { zeros = 0; continue; }
        zeros = nal[n] == 0 ? zeros + 1 : 0;
        rbsp[size++] = nal[n];
    }
    int bit = type == 7 ? 24 : 0;
    if (type == 8 && unsigned_golomb(rbsp, size, &bit) < 0) return -1;
    int id = unsigned_golomb(rbsp, size, &bit);
    if (id < 0 || id >= 32) return -1;
    if (type == 7) { *sps |= UINT32_C(1) << id; return 1; }
    /* A dependent-view PPS may use ordinary NAL type 8 but refer to a
       subset SPS (type 15), which is outside the independent AVC stream. */
    return !!(*sps & (UINT32_C(1) << id));
}

static int base_packet(const AVPacket *in, AVPacket *out, uint32_t *sps)
{
    int ret = av_new_packet(out, in->size), written = 0, picture = 0;
    if (ret < 0) return ret;
    for (int at = 0; at + 3 < in->size;) {
        if (in->data[at] || in->data[at + 1] || in->data[at + 2] != 1) { at++; continue; }
        int end = at + 3;
        while (end + 2 < in->size && (in->data[end] || in->data[end+1] || in->data[end+2] != 1)) end++;
        if (end + 2 >= in->size) end = in->size;
        int type = in->data[at+3] & 31;
        int keep = type >= 1 && type <= 12;
        if (type >= 1 && type <= 5) picture = 1;
        /* Non-VCL headers after the base picture belong to the concatenated
           dependent access unit. In particular, its SEI must not be applied
           as late AVC SEI by the independent frame-threaded decoder. */
        if (picture && type >= 6 && type <= 9) keep = 0;
        if (keep && (type == 7 || type == 8)) {
            keep = base_parameter(in->data + at + 3, end - at - 3, sps);
            if (keep < 0) return AVERROR_INVALIDDATA;
        }
        if (keep) {
            memcpy(out->data + written, in->data + at, end - at);
            written += end - at;
        }
        at = end;
    }
    av_shrink_packet(out, written);
    out->pts = in->pts; out->dts = in->dts; out->duration = in->duration;
    return written ? 0 : AVERROR_INVALIDDATA;
}

int main(int argc, char **argv)
{
    if (argc < 4) { fprintf(stderr, "Usage: %s ISO seconds|all target_seconds...\n", argv[0]); return 2; }
    int full = !strcmp(argv[2], "all"), indexes[2], ret = 0, failed = 0;
    double seconds = full ? 0 : strtod(argv[2], NULL);
    if (!full && seconds <= 0) return 2;
    av_log_set_level(AV_LOG_WARNING);
    AVFormatContext *input = NULL;
    AVCodecContext *decoders[3] = {NULL};
    AVPacket *packet = av_packet_alloc(), *avc = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    if ((ret = avformat_open_input(&input, argv[1], av_find_input_format("bd_mvc"), NULL)) < 0 ||
        (ret = avformat_find_stream_info(input, NULL)) < 0) goto cleanup;
    for (int n = 0; n < 3; n++) {
        if (n < 2) indexes[n] = av_find_best_stream(input, n ? AVMEDIA_TYPE_AUDIO : AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
        if (indexes[n == 1] < 0) { ret = AVERROR_STREAM_NOT_FOUND; goto cleanup; }
        AVStream *stream = input->streams[indexes[n == 1]];
        decoders[n] = avcodec_alloc_context3(avcodec_find_decoder(n == 2 ? AV_CODEC_ID_H264 : stream->codecpar->codec_id));
        if (!decoders[n] || avcodec_parameters_to_context(decoders[n], stream->codecpar) < 0) { ret = AVERROR(ENOMEM); goto cleanup; }
        if (n == 2) {
            decoders[n]->codec_id = AV_CODEC_ID_H264; decoders[n]->width /= 2;
            av_freep(&decoders[n]->extradata); decoders[n]->extradata_size = 0;
            /* This independent AVC reference is validation-only. Parallelize
               its frames without changing the production MVC worker policy. */
            decoders[n]->thread_count = 8;
            decoders[n]->thread_type = FF_THREAD_FRAME;
        }
        decoders[n]->pkt_timebase = stream->time_base;
        if ((ret = avcodec_open2(decoders[n], NULL, NULL)) < 0) goto cleanup;
    }
    const AVStream *video = input->streams[indexes[0]];
    double fps = av_q2d(video->avg_frame_rate), duration = input->duration / (double)AV_TIME_BASE;
    if (fps <= 0 || duration <= 0 || video->codecpar->width != 3840 || video->codecpar->height != 1080) {
        ret = AVERROR_INVALIDDATA; goto cleanup;
    }
    for (int arg = 3; arg < argc; arg++) {
        double target = strtod(argv[arg], NULL), end = full ? duration : fmin(duration, target + seconds);
        Stats stats = {.start = target, .end = end,
            .verify_preroll = getenv("THRU3D_MVC_VERIFY_PREROLL") != NULL,
            .ref_start = INT64_MIN, .ref_end = INT64_MAX,
            .base_eye = video->codecpar->extradata_size == 1 && video->codecpar->extradata[0] == 1};
        int eof = 0, ref_clip = -1;
        uint32_t avc_sps = 0;
        int64_t before = av_gettime_relative();
        if (target < 0 || end <= target) { ret = AVERROR(EINVAL); goto cleanup; }
        if ((ret = avformat_seek_file(input, -1, INT64_MIN, llround(target * AV_TIME_BASE), INT64_MAX, 0)) < 0) goto cleanup;
        for (int d = 0; d < 3; d++) avcodec_flush_buffers(decoders[d]);
        for (;;) {
            ret = av_read_frame(input, packet);
            if (ret == AVERROR_EOF) { eof = 1; ret = 0; break; }
            if (ret < 0) break;
            if (packet->stream_index == indexes[0]) {
                int64_t clip_start = 0, clip_end = INT64_MAX;
                int clip = packet_clip(packet, &clip_start, &clip_end);
                if (clip == -2) { ret = AVERROR_INVALIDDATA; break; }
                if (clip >= 0) {
                    if (clip < 64) stats.clip_mask |= UINT64_C(1) << clip;
                    if (ref_clip >= 0 && ref_clip != clip) {
                        if ((ret = send(decoders[2], NULL, frame, 2, &stats)) < 0) break;
                        avcodec_flush_buffers(decoders[2]);
                        avc_sps = 0;
                    }
                    ref_clip = clip;
                    stats.ref_start = clip_start; stats.ref_end = clip_end;
                }
                if ((ret = send(decoders[0], packet, frame, 0, &stats)) < 0 ||
                    (ret = base_packet(packet, avc, &avc_sps)) < 0 || (ret = send(decoders[2], avc, frame, 2, &stats)) < 0) break;
                av_packet_unref(avc);
            } else if (packet->stream_index == indexes[1]) {
                if ((ret = send(decoders[1], packet, frame, 1, &stats)) < 0) break;
            }
            av_packet_unref(packet);
            if (!full && stats.done[0] && stats.done[1] && stats.done[2]) break;
        }
        av_packet_unref(packet); av_packet_unref(avc);
        if (ret >= 0 && eof) for (int d = 0; d < 3; d++) {
            if ((ret = send(decoders[d], NULL, frame, d, &stats)) < 0) break;
        }
        int passed = ret >= 0 && stats.frames >= floor((end - target) * fps) - 1 &&
            stats.frames == stats.compared && !stats.count[0] && !stats.count[1] && stats.different > 0 &&
            stats.first - target < 1.1 / fps && stats.max_gap < 1.1 / fps &&
            stats.audio_gap < 0.070 && stats.samples >= (end - target - 0.07) * decoders[1]->sample_rate &&
            fabs(stats.audio_end - (stats.last + 1 / fps)) < 0.075 && (!full || eof);
        printf("{\"target\":%.6f,\"seconds\":%.6f,\"full\":%s,\"video_pairs\":%d,\"base_frames_bitexact\":%d,"
               "\"different_eyes\":%d,\"audio_samples\":%"PRId64",\"first_pts\":%.6f,\"last_pts\":%.6f,"
               "\"max_video_gap\":%.6f,\"max_audio_gap\":%.6f,\"audio_end\":%.6f,\"clip_mask\":%"PRIu64","
               "\"eye_hashes\":[\"%016"PRIx64"\",\"%016"PRIx64"\"],\"preroll_checked\":%s,\"preroll_compared\":%d,\"elapsed_seconds\":%.3f,\"error\":%d,\"passed\":%s}\n",
               target, end-target, full ? "true" : "false", stats.frames, stats.compared, stats.different,
               stats.samples, stats.first, stats.last, stats.max_gap, stats.audio_gap, stats.audio_end, stats.clip_mask,
               stats.eyes[0], stats.eyes[1], stats.verify_preroll ? "true" : "false", stats.preroll_compared,
               (av_gettime_relative()-before)/1000000., ret, passed ? "true" : "false");
        fflush(stdout); failed |= !passed;
        for (int eye = 0; eye < 2; eye++) for (int i = 0; i < stats.count[eye]; i++) av_frame_free(&stats.queued[eye][i]);
        if (!passed) break;
    }
cleanup:
    if (ret < 0) { char error[AV_ERROR_MAX_STRING_SIZE]; av_strerror(ret, error, sizeof(error)); fprintf(stderr, "%s\n", error); }
    av_packet_free(&packet); av_packet_free(&avc); av_frame_free(&frame);
    for (int d = 0; d < 3; d++) avcodec_free_context(&decoders[d]);
    avformat_close_input(&input);
    return ret < 0 || failed;
}
