/* Compare every presented seek frame, including preroll, with a warmed decoder.
 * Full per-eye pixel CRCs are retained in memory; no movie images are written. */
#include <inttypes.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include "libavformat/avformat.h"
#include "libavcodec/avcodec.h"
#include "libavutil/crc.h"

typedef struct Picture { int64_t pts; uint32_t eyes[2]; } Picture;
typedef struct Window {
    Picture pictures[1024];
    int size, compared, before_target, mismatch, mode, rejected[2];
    int64_t start, end, target, first;
} Window;

static int inspect(Window *s, const AVFrame *frame)
{
    if (frame->pts >= s->end) return 1;
    if (!s->mode && frame->pts < s->start) return 0;
    if (frame->format != AV_PIX_FMT_YUV420P || frame->pts == AV_NOPTS_VALUE ||
        (frame->flags & AV_FRAME_FLAG_CORRUPT)) return -1;
    Picture picture = {.pts = frame->pts};
    for (int p = 0; p < 3; p++) {
        int w = frame->width >> (p ? 2 : 1), h = frame->height >> (p ? 1 : 0);
        for (int y = 0; y < h; y++) for (int eye = 0; eye < 2; eye++)
            picture.eyes[eye] = av_crc(av_crc_get_table(AV_CRC_32_IEEE), picture.eyes[eye],
                frame->data[p] + (ptrdiff_t)y * frame->linesize[p] + eye * w, w);
    }
    if (!s->mode) {
        if (s->size >= 1024) return -1;
        s->pictures[s->size++] = picture;
    } else {
        int found = 0;
        for (int i = 0; i < s->size; i++) if (s->pictures[i].pts == picture.pts) {
            found = 1;
            if (s->pictures[i].eyes[0] != picture.eyes[0] || s->pictures[i].eyes[1] != picture.eyes[1]) {
                fprintf(stderr, "Seek pixels differ at PTS %"PRId64" (left %d, right %d)\n", picture.pts,
                    s->pictures[i].eyes[0] != picture.eyes[0], s->pictures[i].eyes[1] != picture.eyes[1]);
                s->mismatch++;
            }
            break;
        }
        if (!found) { fprintf(stderr, "No reference for seek PTS %"PRId64"\n", picture.pts); return -1; }
        if (!s->compared) s->first = picture.pts;
        s->compared++;
        s->before_target += picture.pts < s->target;
    }
    return 0;
}

static int decode(AVFormatContext *input, AVCodecContext *codec, int stream, double seek,
                  Window *window, AVPacket *packet, AVFrame *frame)
{
    int ret = avformat_seek_file(input, -1, INT64_MIN, llround(seek * AV_TIME_BASE), INT64_MAX, 0);
    if (ret < 0) return ret;
    avcodec_flush_buffers(codec);
    for (;;) {
        ret = av_read_frame(input, packet);
        if (ret < 0 && ret != AVERROR_EOF) return ret;
        int eof = ret == AVERROR_EOF;
        if (!eof && packet->stream_index != stream) { av_packet_unref(packet); continue; }
        ret = avcodec_send_packet(codec, eof ? NULL : packet);
        av_packet_unref(packet);
        if (ret < 0) return ret;
        int rejected = 0;
        for (;;) {
            ret = avcodec_receive_frame(codec, frame);
            /* A rejected corrupt pair is not presented. Continue like mpv;
               compare every frame the adapter actually publishes. */
            if (ret == AVERROR_INVALIDDATA) {
                if (++rejected > 64) return ret;
                window->rejected[window->mode]++;
                continue;
            }
            if (ret != 0) break;
            int result = inspect(window, frame);
            av_frame_unref(frame);
            if (result) return result < 0 ? AVERROR_INVALIDDATA : 0;
        }
        if (ret != AVERROR(EAGAIN) && ret != AVERROR_EOF) return ret;
        if (eof) return 0;
    }
}

int main(int argc, char **argv)
{
    if (argc < 3) return 2;
    av_log_set_level(AV_LOG_ERROR);
    AVFormatContext *input = NULL;
    AVCodecContext *codec = NULL;
    AVPacket *packet = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    int ret = avformat_open_input(&input, argv[1], av_find_input_format("bd_mvc"), NULL);
    if (ret < 0) goto cleanup;
    if (!packet || !frame) { ret = AVERROR(ENOMEM); goto cleanup; }
    int stream = av_find_best_stream(input, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (stream < 0) { ret = stream; goto cleanup; }
    codec = avcodec_alloc_context3(avcodec_find_decoder(input->streams[stream]->codecpar->codec_id));
    if (!codec) { ret = AVERROR(ENOMEM); goto cleanup; }
    if ((ret = avcodec_parameters_to_context(codec, input->streams[stream]->codecpar)) < 0 ||
        (ret = avcodec_open2(codec, codec->codec, NULL)) < 0) goto cleanup;
    for (int arg = 2; arg < argc; arg++) {
        char *end;
        double target = strtod(argv[arg], &end);
        if (end == argv[arg] || *end || !isfinite(target) || target < 0) { ret = AVERROR(EINVAL); break; }
        Window window = {.start = llround(fmax(0, target - 4) * 90000),
            .end = llround((target + 2) * 90000), .target = llround(target * 90000)};
        ret = decode(input, codec, stream, fmax(0, target - 10), &window, packet, frame);
        if (ret < 0) break;
        window.mode = 1;
        ret = decode(input, codec, stream, target, &window, packet, frame);
        int passed = ret >= 0 && window.compared >= 24 && !window.mismatch;
        printf("{\"target\":%.3f,\"first_pts\":%.6f,\"compared\":%d,\"before_target\":%d,\"mismatch\":%d,\"rejected\":[%d,%d],\"passed\":%s}\n",
            target, window.first / 90000., window.compared, window.before_target, window.mismatch,
            window.rejected[0], window.rejected[1], passed ? "true" : "false");
        fflush(stdout);
        if (!passed) { ret = AVERROR_INVALIDDATA; break; }
    }
cleanup:
    if (ret < 0) { char message[128]; av_strerror(ret, message, sizeof(message)); fprintf(stderr, "%s\n", message); }
    av_packet_free(&packet); av_frame_free(&frame);
    avcodec_free_context(&codec); avformat_close_input(&input);
    return ret < 0;
}
