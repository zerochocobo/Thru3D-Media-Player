#pragma once
// Full-size software fallback when Android's independent frame retriever returns no image.
// Uses the pinned playback libraries; never touches the active playback decoder or its clock.
#include "original_clip_core.h"
extern "C" {
#include <libavcodec/avcodec.h>
#include <libswscale/swscale.h>
}
#include <limits>

namespace quest::capture {
using Frame = std::unique_ptr<AVFrame, void(*)(AVFrame*)>;
inline Frame frame() { return {av_frame_alloc(), [](AVFrame* p) { av_frame_free(&p); }}; }
struct FrameDecoder {
    AVCodecContext* ctx = nullptr;
    ~FrameDecoder() { avcodec_free_context(&ctx); }
};
inline void frame_check(int result) {
    if (result < 0) throw std::runtime_error("Could not capture source frame");
}
inline void frame_size(int width, int height) {
    if (width <= 0 || height <= 0 || int64_t(width) * height > 40LL * 1024 * 1024)
        throw std::runtime_error("Full resolution capture unavailable");
}
inline Frame source_frame(const std::string& path, int64_t position, const std::string& ca, Control& control) {
    if (position < 0) throw std::runtime_error("Could not capture source frame");
    Input input;
    input.open(path, ca, control);
    const int video = av_find_best_stream(input.ctx, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
    frame_check(video);
    const auto* stream = input.ctx->streams[video];
    frame_size(stream->codecpar->width, stream->codecpar->height);
    const auto* codec = avcodec_find_decoder(stream->codecpar->codec_id);
    if (!codec) throw std::runtime_error("Could not capture source frame");
    FrameDecoder decoder;
    decoder.ctx = avcodec_alloc_context3(codec);
    if (!decoder.ctx) throw std::bad_alloc();
    frame_check(avcodec_parameters_to_context(decoder.ctx, stream->codecpar));
    decoder.ctx->pkt_timebase = stream->time_base;
    // Explicit software decoder, bounded parallelism and allocation. No MediaCodec instance.
    decoder.ctx->thread_count = 2;
    decoder.ctx->thread_type = FF_THREAD_SLICE;
    decoder.ctx->max_pixels = 40LL * 1024 * 1024;
    frame_check(avcodec_open2(decoder.ctx, codec, nullptr));
    if (position > std::numeric_limits<int64_t>::max() - std::max<int64_t>(0, input.origin()))
        throw std::runtime_error("Could not capture source frame");
    frame_check(av_seek_frame(input.ctx, video,
        av_rescale_q(position + input.origin(), AV_TIME_BASE_Q, stream->time_base), AVSEEK_FLAG_BACKWARD));
    auto current = frame(), previous = frame();
    auto packet_value = packet();
    if (!current || !previous || !packet_value) throw std::bad_alloc();
    bool flushing = false;
    int64_t previous_time = AV_NOPTS_VALUE;
    while (true) {
        if (Control::interrupt(&control)) throw std::runtime_error("Could not capture source frame");
        const int received = avcodec_receive_frame(decoder.ctx, current.get());
        if (received >= 0) {
            frame_size(current->width, current->height);
            if (current->width != stream->codecpar->width || current->height != stream->codecpar->height)
                throw std::runtime_error("Full resolution capture unavailable");
            const int64_t timestamp = micros(current->best_effort_timestamp, stream->time_base);
            if (timestamp == AV_NOPTS_VALUE) throw std::runtime_error("Could not capture source frame");
            const int64_t time = timestamp - input.origin();
            current->pts = time; // Result PTS is relative microseconds, for validation/diagnostics.
            // Decode forwards from the preceding keyframe, including reordered B frames.
            // Choose the nearest decoded frame at the requested time, never just that keyframe.
            if (time >= position) {
                if (previous_time != AV_NOPTS_VALUE && position - previous_time <= time - position) {
                    if (position - previous_time > 1000000) throw std::runtime_error("Could not capture source frame");
                    return previous;
                }
                if (time - position > 1000000) throw std::runtime_error("Could not capture source frame");
                return current;
            }
            av_frame_unref(previous.get()); av_frame_move_ref(previous.get(), current.get());
            previous_time = time;
            continue;
        }
        if (received == AVERROR_EOF) {
            // A final frame can cover the requested instant at EOF; an arbitrary old frame cannot.
            const int64_t duration = micros(previous->duration, stream->time_base);
            if (previous_time != AV_NOPTS_VALUE && position - previous_time <= std::max<int64_t>(duration, 100000))
                return previous;
            throw std::runtime_error("Could not capture source frame");
        }
        frame_check(received == AVERROR(EAGAIN) ? 0 : received);
        if (flushing) throw std::runtime_error("Could not capture source frame");
        int read;
        do {
            av_packet_unref(packet_value.get());
            if (Control::interrupt(&control)) throw std::runtime_error("Could not capture source frame");
            read = av_read_frame(input.ctx, packet_value.get());
        } while (read >= 0 && packet_value->stream_index != video);
        if (read == AVERROR_EOF) {
            frame_check(avcodec_send_packet(decoder.ctx, nullptr)); flushing = true;
        } else {
            frame_check(read); frame_check(avcodec_send_packet(decoder.ctx, packet_value.get()));
        }
    }
}
inline void frame_rgba(const AVFrame& source, uint8_t* pixels, int pitch) {
    frame_size(source.width, source.height);
    if (!pixels || pitch < source.width * 4) throw std::runtime_error("Could not capture source frame");
    auto* scale = sws_getContext(source.width, source.height, static_cast<AVPixelFormat>(source.format),
        source.width, source.height, AV_PIX_FMT_RGBA, SWS_BILINEAR, nullptr, nullptr, nullptr);
    if (!scale) throw std::runtime_error("Could not capture source frame");
    const std::unique_ptr<SwsContext, decltype(&sws_freeContext)> owned(scale, sws_freeContext);
    const int matrix = source.colorspace == AVCOL_SPC_BT709 ? SWS_CS_ITU709 :
        source.colorspace == AVCOL_SPC_BT2020_NCL || source.colorspace == AVCOL_SPC_BT2020_CL ? SWS_CS_BT2020 :
        source.colorspace == AVCOL_SPC_SMPTE240M ? SWS_CS_SMPTE240M :
        source.colorspace == AVCOL_SPC_UNSPECIFIED && source.height > 576 ? SWS_CS_ITU709 : SWS_CS_ITU601;
    const int* coefficients = sws_getCoefficients(matrix);
    frame_check(sws_setColorspaceDetails(scale, coefficients, source.color_range == AVCOL_RANGE_JPEG,
        coefficients, 1, 0, 1 << 16, 1 << 16));
    uint8_t* target[4] = {pixels, nullptr, nullptr, nullptr};
    const int lines[4] = {pitch, 0, 0, 0};
    if (sws_scale(scale, source.data, source.linesize, 0, source.height, target, lines) != source.height)
        throw std::runtime_error("Could not capture source frame");
}
} // namespace quest::capture
