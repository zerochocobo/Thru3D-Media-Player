#pragma once
extern "C" {
#include <libavformat/avformat.h>
}
#include "disc_probe.h"
#include <algorithm>
#include <dlfcn.h>
#include <string>

namespace quest {
struct MkvMvcInfo { bool mvc = false; int width = 0, height = 0; int64_t read_bytes = 0; };

// Use the already resolved playback lease. No stream analysis, decoding, disk
// cache or account lookup; the source worker keeps the lease alive until close.
inline MkvMvcInfo probe_mkv_mvc(const std::string& path, const std::string& ca, DiscProbe& control) {
    struct Reader {
        AVIOContext *source = nullptr, *io = nullptr;
        AVFormatContext *format = nullptr;
        DiscProbe *control = nullptr;
        int64_t bytes = 0;
        static int read(void *opaque, uint8_t *data, int size) {
            auto& self = *static_cast<Reader*>(opaque);
            if (DiscProbe::interrupt(self.control)) return AVERROR_EXIT;
            constexpr int64_t limit = 8 * 1024 * 1024;
            if (self.bytes >= limit) return AVERROR(ENOBUFS);
            int result = avio_read(self.source, data, static_cast<int>(std::min<int64_t>(size, limit - self.bytes)));
            if (result > 0) self.bytes += result;
            return result;
        }
        static int64_t seek(void *opaque, int64_t offset, int whence) {
            auto& self = *static_cast<Reader*>(opaque);
            if (DiscProbe::interrupt(self.control)) return AVERROR_EXIT;
            return whence == AVSEEK_SIZE ? avio_size(self.source) : avio_seek(self.source, offset, whence);
        }
        ~Reader() {
            avformat_close_input(&format);
            if (io) { av_freep(&io->buffer); avio_context_free(&io); }
            avio_closep(&source);
        }
    } input;
    input.control = &control;
    AVDictionary *options = nullptr;
    av_dict_set(&options, "tls_verify", "1", 0);
    if (!ca.empty()) av_dict_set(&options, "ca_file", ca.c_str(), 0);
    av_dict_set(&options, "rw_timeout", "45000000", 0);
    av_dict_set(&options, "user_agent", "Thru3D (MVC header)", 0);
    AVIOInterruptCB interrupt{DiscProbe::interrupt, &control};
    int ret = avio_open2(&input.source, path.c_str(), AVIO_FLAG_READ, &interrupt, &options);
    av_dict_free(&options);
    if (ret < 0) throw std::runtime_error("MKV header source open failed: " + std::to_string(ret));
    // Preserve ordinary linear HTTP playback. MVC preflight needs random reads
    // to skip attachments; an unseekable input keeps its original player path.
    if (!(input.source->seekable & AVIO_SEEKABLE_NORMAL)) return {};
    auto *buffer = static_cast<uint8_t*>(av_malloc(32768));
    if (!buffer) throw std::runtime_error("MKV header allocation failed");
    input.io = avio_alloc_context(buffer, 32768, 0, &input, Reader::read, nullptr, Reader::seek);
    if (!input.io) { av_free(buffer); throw std::runtime_error("MKV header reader unavailable"); }
    input.io->seekable = input.source->seekable;
    input.format = avformat_alloc_context();
    if (!input.format) throw std::runtime_error("MKV header context unavailable");
    input.format->pb = input.io;
    input.format->flags |= AVFMT_FLAG_CUSTOM_IO;
    input.format->interrupt_callback = interrupt;
    using HeaderFormat = const AVInputFormat *(*)();
    auto header_format = reinterpret_cast<HeaderFormat>(dlsym(RTLD_DEFAULT, "avformat_thru3d_mkv_header_format"));
    const AVInputFormat *matroska = header_format ? header_format() : nullptr;
    if (!matroska) throw std::runtime_error("MKV decoder build unavailable");
    ret = avformat_open_input(&input.format, nullptr, matroska, nullptr);
    if (ret < 0 || DiscProbe::interrupt(&control))
        throw std::runtime_error("MKV header preflight failed: " + std::to_string(ret));
    MkvMvcInfo result;
    result.read_bytes = input.bytes;
    unsigned videos = 0;
    for (unsigned i = 0; i < input.format->nb_streams; ++i) {
        auto *stream = input.format->streams[i];
        if (stream->codecpar->codec_type != AVMEDIA_TYPE_VIDEO || (stream->disposition & AV_DISPOSITION_ATTACHED_PIC)) continue;
        ++videos;
        auto *tag = av_dict_get(stream->metadata, "thru3d_mvc_mkv", nullptr, 0);
        if (tag && std::string(tag->value) == "1") {
            result.mvc = true;
            result.width = stream->codecpar->width; result.height = stream->codecpar->height;
        }
    }
    if (result.mvc && (videos != 1 || result.width <= 0 || result.width > 3840 ||
        result.width % 2 || result.height <= 0 || result.height > 1080))
        throw std::runtime_error("Unsupported MVC video track layout");
    return result;
}
}
