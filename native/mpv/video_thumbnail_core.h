#pragma once
#include "original_frame_core.h"
#include <functional>
#include <string_view>

namespace quest::capture {
// The demuxer sees only this object. Seeking spends the same byte budget as sequential reads.
struct ThumbnailInput {
    static constexpr int block = 128 * 1024;
    int64_t size, remaining;
    std::function<int(int64_t, uint8_t*, int)> read;
    std::function<bool()> cancelled;
    int64_t max_pixels = 4096LL * 2304;
    bool seekable = true;
    std::chrono::steady_clock::time_point deadline =
        std::chrono::steady_clock::now() + std::chrono::milliseconds(1600);
    int64_t offset = 0;
    int reads = 0;
    const char* issue = "input_unavailable";
    AVCodecID codec_id = AV_CODEC_ID_NONE;
    AVFormatContext* format = nullptr;
    AVIOContext* io = nullptr;

    ~ThumbnailInput() {
        avformat_close_input(&format);
        if (io) { av_freep(&io->buffer); avio_context_free(&io); }
    }
    static int interrupt(void* opaque) {
        auto& self = *static_cast<ThumbnailInput*>(opaque);
        return std::chrono::steady_clock::now() >= self.deadline || self.cancelled();
    }
    static int bytes(void* opaque, uint8_t* data, int length) {
        auto& self = *static_cast<ThumbnailInput*>(opaque);
        if (interrupt(opaque)) return AVERROR_EXIT;
        if (self.size > 0 && self.offset == self.size) return AVERROR_EOF;
        if (self.remaining <= 0 || ++self.reads > 80) {
            self.issue = "read_limit";
            return AVERROR(EIO);
        }
        const auto available = self.size > 0 ? self.size - self.offset : self.remaining;
        const int requested = int(std::min({int64_t(std::min(length, block)), available, self.remaining}));
        const int count = self.read(self.offset, data, requested);
        if (count == 0 && !self.seekable) return AVERROR_EOF;
        if (count <= 0 || count > requested) {
            self.issue = "short_read";
            return AVERROR(EIO);
        }
        self.offset += count;
        self.remaining -= count;
        return count;
    }
    static int64_t seek(void* opaque, int64_t value, int whence) {
        auto& self = *static_cast<ThumbnailInput*>(opaque);
        if (whence == AVSEEK_SIZE) return self.size;
        whence &= ~AVSEEK_FORCE;
        const auto base = whence == SEEK_SET ? 0 : whence == SEEK_CUR ? self.offset : self.size;
        if (whence != SEEK_SET && whence != SEEK_CUR && whence != SEEK_END) return AVERROR(EINVAL);
        if (value < -base || value > self.size - base) return AVERROR(EINVAL);
        return self.offset = base + value;
    }
    bool open() {
        auto* buffer = static_cast<uint8_t*>(av_malloc(block));
        if (!buffer) return false;
        io = avio_alloc_context(buffer, block, 0, this, bytes, nullptr, seekable ? seek : nullptr);
        if (!io) { av_free(buffer); return false; }
        format = avformat_alloc_context();
        if (!format) return false;
        format->pb = io;
        format->flags |= AVFMT_FLAG_CUSTOM_IO;
        format->max_streams = 32;
        format->interrupt_callback = {interrupt, this};
        format->io_open = [](AVFormatContext*, AVIOContext**, const char*, int, AVDictionary**) {
            return AVERROR(EACCES);
        };
        AVDictionary* options = nullptr;
        // Self-contained inputs only. No demuxer may follow a playlist or an external resource.
        av_dict_set(&options, "format_whitelist",
            "matroska,webm,mov,mp4,m4a,3gp,3g2,mj2,avi,asf,flv,mpegts,mpeg,mpegvideo,bd_mvc,ogg,ivf,m4v,h264,hevc,av1,vc1", 0);
        av_dict_set(&options, "formatprobesize", "262144", 0);
        issue = "container_unreadable";
        const int opened = avformat_open_input(&format, nullptr, nullptr, &options);
        av_dict_free(&options);
        return opened >= 0;
    }
};

inline Frame thumbnail_frame(ThumbnailInput& input) {
    if ((input.seekable && input.size <= 0) || (!input.format && !input.open())) return {nullptr, nullptr};
    auto decoded = frame();
    auto data = packet();
    if (!decoded || !data) return {nullptr, nullptr};
    FrameDecoder decoder;
    input.issue = "no_video_track";
    const std::string_view container(input.format->iformat->name);
    const bool packetized = container == "mpegts" || container == "mpeg" || container == "mpegvideo" ||
        container == "bd_mvc" || container == "h264" || container == "hevc" || container == "m4v" || container == "vc1";
    int index = -1;
    for (int count = 0; count < 192 && !ThumbnailInput::interrupt(&input); ++count) {
        if (av_read_frame(input.format, data.get()) < 0) break;
        if (index < 0) {
            // TS and program streams can announce dimensions only when packets arrive.
            const auto* stream = input.format->streams[data->stream_index];
            const auto* parameters = stream->codecpar;
            const auto* codec = avcodec_find_decoder(parameters->codec_id);
            if (parameters->codec_type == AVMEDIA_TYPE_VIDEO && !(stream->disposition & AV_DISPOSITION_ATTACHED_PIC)) {
                input.codec_id = parameters->codec_id;
                if (!codec) {
                    input.issue = "decoder_unavailable";
                    av_packet_unref(data.get());
                    continue;
                }
                if (int64_t(parameters->width) * parameters->height > input.max_pixels) {
                    input.issue = "memory_limit";
                    break;
                }
                input.issue = "decoder_open_failed";
                decoder.ctx = avcodec_alloc_context3(codec);
                if (!decoder.ctx || avcodec_parameters_to_context(decoder.ctx, parameters) < 0) break;
                decoder.ctx->thread_count = 1;
                decoder.ctx->max_pixels = input.max_pixels;
                decoder.ctx->skip_frame = AVDISCARD_NONKEY;
                decoder.ctx->skip_loop_filter = AVDISCARD_ALL;
                // Some codecs perform a reduced-resolution inverse transform and never
                // allocate a full-size picture. Keep enough detail for a 320-pixel preview.
                int edge = std::max(parameters->width, parameters->height);
                if (edge == 0 && packetized) edge = 720;
                while (edge >= 640 && decoder.ctx->lowres < codec->max_lowres) {
                    ++decoder.ctx->lowres;
                    edge /= 2;
                }
                if (avcodec_open2(decoder.ctx, codec, nullptr) < 0) break;
                index = data->stream_index;
                input.issue = "no_frame";
            }
        }
        if (data->stream_index == index && (packetized || (data->flags & AV_PKT_FLAG_KEY))) {
            if (avcodec_send_packet(decoder.ctx, data.get()) >= 0) {
                const int received = avcodec_receive_frame(decoder.ctx, decoded.get());
                if (received >= 0) return decoded;
                // The decoder may retain the opening keyframe for reordering even though
                // the preview never feeds inter frames. Drain it before reading another packet.
                if (!packetized && received == AVERROR(EAGAIN) && avcodec_send_packet(decoder.ctx, nullptr) >= 0 &&
                    avcodec_receive_frame(decoder.ctx, decoded.get()) >= 0) return decoded;
            }
            if (!packetized) avcodec_flush_buffers(decoder.ctx);
        }
        av_packet_unref(data.get());
    }
    if (packetized && decoder.ctx && !ThumbnailInput::interrupt(&input) &&
        avcodec_send_packet(decoder.ctx, nullptr) >= 0 && avcodec_receive_frame(decoder.ctx, decoded.get()) >= 0)
        return decoded;
    return {nullptr, nullptr};
}
} // namespace quest::capture
