/* Verify the exact decoder helper on raw MV-HEVC and synthetic eye pairs. */
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <libavformat/avformat.h>
#include <libavutil/opt.h>
#include "../../native/mpv/spatial/quest_spatial_video.h"
#include "../../native/mpv/spatial/quest_spatial_metadata.h"

static void metadata_tests(void)
{
    _Static_assert(sizeof(quest_mpv_source_frame) == 80, "Keep API-2 ABI");
    _Static_assert(sizeof(quest_mpv_spatial_metadata) == 32, "Spatial ABI");
    AVStereo3D stereo = {0};
    quest_mpv_spatial_metadata out;
    quest_spatial_metadata_read(&out, NULL);
    assert(out.struct_size == sizeof(out) && !out.flags);
    stereo.baseline = 19200;
    stereo.horizontal_field_of_view = (AVRational){63400, 1000};
    stereo.horizontal_disparity_adjustment = (AVRational){200, 10000};
    quest_spatial_metadata_read(&out, &stereo);
    assert(out.flags == (QUEST_MPV_SPATIAL_BASELINE | QUEST_MPV_SPATIAL_FOV | QUEST_MPV_SPATIAL_DISPARITY));
    assert(fabs(out.baseline_meters - .0192) < 1e-12);
    assert(fabs(out.horizontal_fov_degrees - 63.4) < 1e-12);
    assert(fabs(out.horizontal_disparity - .02) < 1e-12);
    stereo.horizontal_disparity_adjustment.num = -200;
    quest_spatial_metadata_read(&out, &stereo);
    assert(fabs(out.horizontal_disparity + .02) < 1e-12);
    stereo.horizontal_disparity_adjustment.num = 0;
    quest_spatial_metadata_read(&out, &stereo);
    assert((out.flags & QUEST_MPV_SPATIAL_DISPARITY) && out.horizontal_disparity == 0);
    stereo.baseline = 0;
    stereo.horizontal_field_of_view = (AVRational){180, 1};
    stereo.horizontal_disparity_adjustment = (AVRational){10001, 10000};
    quest_spatial_metadata_read(&out, &stereo);
    assert(!out.flags && out.baseline_meters == 0 && out.horizontal_disparity == 0);
    stereo.horizontal_field_of_view = (AVRational){63, 0};
    stereo.horizontal_disparity_adjustment = (AVRational){2, -100};
    quest_spatial_metadata_read(&out, &stereo);
    assert(!out.flags);
    puts("Spatial metadata units, sign, zero, missing/invalid fields and ABI: passed");
}

static AVFrame *eye(int view, int64_t pts, int value)
{
    AVFrame *f = av_frame_alloc();
    assert(f);
    f->format = AV_PIX_FMT_YUV420P;
    f->width = 16; f->height = 8; f->pts = pts;
    assert(av_frame_get_buffer(f, 32) == 0);
    for (int p = 0; p < 3; p++)
        for (int y = 0; y < (p ? 4 : 8); y++)
            memset(f->data[p] + y * f->linesize[p], value + p, p ? 8 : 16);
    AVStereo3D *sd = av_stereo3d_create_side_data(f);
    assert(sd);
    sd->type = AV_STEREO3D_FRAMESEQUENCE;
    sd->view = view;
    return f;
}

static void unit_tests(void)
{
    struct quest_spatial_pair pair = {0};
    AVFrame *r = eye(AV_STEREO3D_VIEW_RIGHT, 10, 180);
    AVFrame *l = eye(AV_STEREO3D_VIEW_LEFT, 10, 30);
    assert(quest_spatial_join(&pair, r) == 0);
    assert(quest_spatial_join(&pair, l) == 1);
    assert(l->width == 32 && l->height == 8 && l->pts == 10);
    for (int p = 0; p < 3; p++) {
        int w = p ? 8 : 16, h = p ? 4 : 8;
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++) {
                assert(l->data[p][y * l->linesize[p] + x] == 30 + p);
                assert(l->data[p][y * l->linesize[p] + x + w] == 180 + p);
            }
    }
    assert(!pair.eye[0] && !pair.eye[1]);
    av_frame_free(&l); av_frame_free(&r);
    l = eye(AV_STEREO3D_VIEW_LEFT, 20, 30);
    r = eye(AV_STEREO3D_VIEW_RIGHT, 21, 180);
    assert(quest_spatial_join(&pair, l) == 0);
    assert(quest_spatial_join(&pair, r) == 0);
    assert(!pair.eye[0] && pair.eye[1]);
    quest_spatial_clear(&pair); // seek must discard the unmatched pre-seek eye
    av_frame_free(&l); av_frame_free(&r);
    l = eye(AV_STEREO3D_VIEW_LEFT, 21, 30);
    assert(quest_spatial_join(&pair, l) == 0);
    quest_spatial_clear(&pair); av_frame_free(&l);
    l = eye(AV_STEREO3D_VIEW_UNSPEC, 30, 30);
    assert(quest_spatial_join(&pair, l) == AVERROR_INVALIDDATA);
    av_frame_free(&l);
    l = eye(AV_STEREO3D_VIEW_LEFT, AV_NOPTS_VALUE, 30);
    assert(quest_spatial_join(&pair, l) == AVERROR_INVALIDDATA);
    av_frame_free(&l);
    uint8_t vps[32] = {1}; // hvcC with one 4-byte VPS and two layers
    vps[22] = 1; vps[23] = 32; vps[25] = 1; vps[27] = 4;
    vps[28] = 64; vps[29] = 1; vps[31] = 16;
    assert(quest_spatial_multilayer(vps, 32));
    for (int length = 0; length < 32; length++)
        assert(!quest_spatial_multilayer(vps, length));
    AVCodecParameters *par = avcodec_parameters_alloc();
    assert(par);
    par->codec_id = AV_CODEC_ID_HEVC;
    par->extradata = av_memdup(vps, sizeof(vps));
    par->extradata_size = sizeof(vps);
    assert(!quest_spatial_candidate(par)); // multilayer alone is not spatial
    size_t size;
    AVStereo3D *sd = av_stereo3d_alloc_size(&size);
    assert(sd);
    sd->type = AV_STEREO3D_UNSPEC;
    assert(av_packet_side_data_add(&par->coded_side_data, &par->nb_coded_side_data,
                                   AV_PKT_DATA_STEREO3D, (uint8_t *)sd, size, 0));
    assert(quest_spatial_candidate(par));
    sd->type = AV_STEREO3D_SIDEBYSIDE;
    assert(!quest_spatial_candidate(par));
    sd->type = AV_STEREO3D_UNSPEC;
    assert(av_packet_side_data_new(&par->coded_side_data, &par->nb_coded_side_data,
                                   AV_PKT_DATA_DOVI_CONF, 1, 0));
    assert(!quest_spatial_candidate(par)); // keep Dolby Vision on its own path
    avcodec_parameters_free(&par);
    puts("Synthetic eye order, chroma packing, PTS mismatch, reset and detection: passed");
}

static int receive(AVCodecContext *codec, struct quest_spatial_pair *pair,
                   AVFrame *frame, int64_t *last, int *different,
                   const quest_mpv_spatial_metadata *expected)
{
    int count = 0, ret;
    while ((ret = avcodec_receive_frame(codec, frame)) >= 0) {
        ret = quest_spatial_join(pair, frame);
        assert(ret >= 0);
        if (ret) {
            assert(frame->pts > *last);
            *last = frame->pts;
            const AVStereo3D *sd = (const AVStereo3D *)av_frame_get_side_data(
                frame, AV_FRAME_DATA_STEREO3D)->data;
            assert(sd->type == AV_STEREO3D_SIDEBYSIDE && sd->view == AV_STEREO3D_VIEW_PACKED);
            quest_mpv_spatial_metadata actual;
            quest_spatial_metadata_read(&actual, sd);
            assert(actual.flags == expected->flags);
            assert(fabs(actual.baseline_meters - expected->baseline_meters) < 1e-12);
            assert(fabs(actual.horizontal_fov_degrees - expected->horizontal_fov_degrees) < 1e-12);
            assert(fabs(actual.horizontal_disparity - expected->horizontal_disparity) < 1e-12);
            int width = frame->width / 2;
            for (int y = 0; y < frame->height; y++)
                if (memcmp(frame->data[0] + y * frame->linesize[0],
                           frame->data[0] + y * frame->linesize[0] + width, width)) {
                    (*different)++; break;
                }
            count++;
        }
        av_frame_unref(frame);
    }
    assert(ret == AVERROR(EAGAIN) || ret == AVERROR_EOF);
    return count;
}

/* Independent base-layer decoder: QuickTime edit lists and decoder reordering
 * make both nb_frames and packet counts unreliable as presentation counts. */
static int reference_count(const char *path)
{
    AVFormatContext *format = NULL;
    assert(avformat_open_input(&format, path, NULL, NULL) == 0);
    assert(avformat_find_stream_info(format, NULL) >= 0);
    int stream = av_find_best_stream(format, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    assert(stream >= 0);
    const AVCodec *decoder = avcodec_find_decoder(format->streams[stream]->codecpar->codec_id);
    AVCodecContext *codec = avcodec_alloc_context3(decoder);
    assert(codec && avcodec_parameters_to_context(codec, format->streams[stream]->codecpar) == 0);
    codec->thread_count = 4;
    assert(avcodec_open2(codec, decoder, NULL) == 0);
    AVPacket *packet = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    assert(packet && frame);
    int count = 0;
    while (av_read_frame(format, packet) >= 0) {
        if (packet->stream_index == stream) {
            assert(avcodec_send_packet(codec, packet) == 0);
            while (avcodec_receive_frame(codec, frame) >= 0) {
                count++;
                av_frame_unref(frame);
            }
        }
        av_packet_unref(packet);
    }
    assert(avcodec_send_packet(codec, NULL) == 0);
    while (avcodec_receive_frame(codec, frame) >= 0) {
        count++;
        av_frame_unref(frame);
    }
    av_packet_free(&packet); av_frame_free(&frame);
    avcodec_free_context(&codec); avformat_close_input(&format);
    return count;
}

static void test_file(const char *path)
{
    int expected = reference_count(path);
    AVFormatContext *format = NULL;
    assert(avformat_open_input(&format, path, NULL, NULL) == 0);
    assert(avformat_find_stream_info(format, NULL) >= 0);
    int stream = av_find_best_stream(format, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    assert(stream >= 0);
    AVCodecParameters *par = format->streams[stream]->codecpar;
    assert(quest_spatial_candidate(par));
    const AVPacketSideData *stereo = av_packet_side_data_get(par->coded_side_data, par->nb_coded_side_data, AV_PKT_DATA_STEREO3D);
    assert(stereo && stereo->size >= sizeof(AVStereo3D));
    quest_mpv_spatial_metadata expected_metadata;
    quest_spatial_metadata_read(&expected_metadata, (const AVStereo3D *)stereo->data);
    printf("Metadata flags=%u baseline=%.6fm FOV=%.3fdeg disparity=%.6f\n", expected_metadata.flags,
           expected_metadata.baseline_meters, expected_metadata.horizontal_fov_degrees, expected_metadata.horizontal_disparity);
    const AVCodec *decoder = avcodec_find_decoder(par->codec_id);
    AVCodecContext *codec = avcodec_alloc_context3(decoder);
    assert(codec && avcodec_parameters_to_context(codec, par) == 0);
    codec->thread_count = 4;
    codec->pkt_timebase = format->streams[stream]->time_base;
    assert(av_opt_set(codec, "view_ids", "-1", AV_OPT_SEARCH_CHILDREN) == 0);
    assert(avcodec_open2(codec, decoder, NULL) == 0);
    AVPacket *packet = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    assert(packet && frame);
    struct quest_spatial_pair pair = {0};
    for (int pass = 0; pass < 2; pass++) {
        int count = 0, different = 0;
        int64_t last = INT64_MIN;
        while (av_read_frame(format, packet) >= 0) {
            if (packet->stream_index == stream) {
                int ret;
                while ((ret = avcodec_send_packet(codec, packet)) == AVERROR(EAGAIN))
                    count += receive(codec, &pair, frame, &last, &different, &expected_metadata);
                assert(ret == 0);
                count += receive(codec, &pair, frame, &last, &different, &expected_metadata);
            }
            av_packet_unref(packet);
        }
        assert(avcodec_send_packet(codec, NULL) == 0);
        count += receive(codec, &pair, frame, &last, &different, &expected_metadata);
        assert(count > 0 && count == expected && different == count);
        assert(!pair.eye[0] && !pair.eye[1]);
        printf("%s: pass %d, %d complete stereo frames, %d different eye pairs\n",
               path, pass + 1, count, different);
        quest_spatial_clear(&pair);
        avcodec_flush_buffers(codec);
        if (!pass) assert(av_seek_frame(format, stream, 0, AVSEEK_FLAG_BACKWARD) >= 0);
    }
    av_packet_free(&packet); av_frame_free(&frame);
    avcodec_free_context(&codec); avformat_close_input(&format);
}

int main(int argc, char **argv)
{
    metadata_tests();
    unit_tests();
    for (int i = 1; i < argc; i++) test_file(argv[i]);
    return 0;
}
