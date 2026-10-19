#pragma once
// Packet-only export shared verbatim by Android JNI and the host integration fixture.
extern "C" {
#include <libavformat/avformat.h>
}
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cerrno>
#include <deque>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>
#include "json_quote.h"

namespace quest::capture {
struct Control {
    std::atomic<bool> cancelled{false};
    std::chrono::steady_clock::time_point deadline = std::chrono::steady_clock::now() + std::chrono::minutes(30);
    static int interrupt(void* value) {
        auto* self = static_cast<Control*>(value);
        return self->cancelled.load() || std::chrono::steady_clock::now() >= self->deadline;
    }
};
inline void check(int result) {
    if (result == AVERROR(ENOSPC)) throw std::runtime_error("Not enough storage");
    if (result < 0) throw std::runtime_error("Clip export failed");
}
inline int64_t micros(int64_t value, AVRational base) {
    return value == AV_NOPTS_VALUE ? AV_NOPTS_VALUE : av_rescale_q(value, base, AV_TIME_BASE_Q);
}
struct Input {
    AVFormatContext* ctx = nullptr;
    std::deque<AVPacket*> queued;
    ~Input() { for (auto* item : queued) av_packet_free(&item); if (ctx) avformat_close_input(&ctx); }
    int read(AVPacket* item) {
        if (queued.empty()) return av_read_frame(ctx, item);
        auto* first = queued.front(); queued.pop_front(); av_packet_move_ref(item, first); av_packet_free(&first); return 0;
    }
    // Matroska omits the first reordered DTS values after a seek. Infer only this bounded prefix
    // backwards from the first real DTS and packet durations; never manufacture a new frame rate.
    void prime_video_timestamps(int video) {
        std::vector<AVPacket*> missing;
        int64_t anchor = AV_NOPTS_VALUE;
        size_t bytes = 0;
        for (int count = 0; count < 256; ++count) {
            AVPacket* item = av_packet_alloc(); if (!item) throw std::bad_alloc();
            const int code = av_read_frame(ctx, item);
            if (code < 0) { av_packet_free(&item); if (code != AVERROR_EOF) check(code); break; }
            queued.push_back(item); bytes += item->size;
            if (bytes > 32 * 1024 * 1024) throw std::runtime_error("Clip timestamps unavailable");
            if (item->stream_index != video) continue;
            if (item->dts != AV_NOPTS_VALUE) { anchor = item->dts; break; }
            missing.push_back(item);
            if (missing.size() >= 64) break;
        }
        if (missing.empty()) return;
        if (anchor == AV_NOPTS_VALUE) {
            int64_t previous = AV_NOPTS_VALUE;
            if (ctx->streams[video]->codecpar->video_delay > 0) throw std::runtime_error("Clip timestamps unavailable");
            for (auto* item : missing) {
                if (item->pts == AV_NOPTS_VALUE || (previous != AV_NOPTS_VALUE && item->pts < previous)) throw std::runtime_error("Clip timestamps unavailable");
                item->dts = previous = item->pts;
            }
            return;
        }
        for (auto it = missing.rbegin(); it != missing.rend(); ++it) {
            if ((*it)->duration <= 0) throw std::runtime_error("Clip timestamps unavailable");
            anchor -= (*it)->duration; (*it)->dts = anchor;
        }
    }
    int64_t origin() const { return ctx->start_time == AV_NOPTS_VALUE ? 0 : ctx->start_time; }
    void open(const std::string& path, const std::string& ca, Control& control) {
        ctx = avformat_alloc_context(); if (!ctx) throw std::bad_alloc();
        ctx->interrupt_callback = {Control::interrupt, &control};
        AVDictionary* options = nullptr;
        av_dict_set(&options, "tls_verify", "1", 0);
        if (!ca.empty()) av_dict_set(&options, "ca_file", ca.c_str(), 0);
        av_dict_set(&options, "rw_timeout", "15000000", 0);
        av_dict_set(&options, "user_agent", "Thru3D (original clip export)", 0);
        const int opened = avformat_open_input(&ctx, path.c_str(), nullptr, &options);
        av_dict_free(&options); check(opened); check(avformat_find_stream_info(ctx, nullptr));
        if (!ctx->pb || !(ctx->pb->seekable & AVIO_SEEKABLE_NORMAL)) throw std::runtime_error("This source cannot export clips");
    }
};
struct Output {
    AVFormatContext* ctx = nullptr;
    ~Output() { if (ctx) { if (ctx->pb) avio_closep(&ctx->pb); avformat_free_context(ctx); } }
};
using Packet = std::unique_ptr<AVPacket, void(*)(AVPacket*)>;
inline Packet packet() { return {av_packet_alloc(), [](AVPacket* p) { av_packet_free(&p); }}; }

inline std::string clip(const std::string& path, const std::string& output_path, int64_t start, int64_t end,
                        int selected_audio, const std::string& audio_path, const std::string& ca,
                        const std::string& mode, Control& control) {
    try {
        if (start < 0 || end <= start) throw std::runtime_error("Recording is empty");
        Input input, extra;
        input.open(path, ca, control);
        const int video = av_find_best_stream(input.ctx, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0); check(video);
        Input* audio_source = &input;
        int audio = selected_audio;
        if (!audio_path.empty()) {
            extra.open(audio_path, ca, control); audio_source = &extra;
            audio = av_find_best_stream(extra.ctx, AVMEDIA_TYPE_AUDIO, -1, -1, nullptr, 0); check(audio);
        }
        if (audio >= static_cast<int>(audio_source->ctx->nb_streams) || (audio >= 0 &&
            audio_source->ctx->streams[audio]->codecpar->codec_type != AVMEDIA_TYPE_AUDIO))
            throw std::runtime_error("Audio track unavailable for export");
        const auto* mp4 = av_guess_format("mp4", nullptr, nullptr);
        bool use_mp4 = mp4 && avformat_query_codec(mp4, input.ctx->streams[video]->codecpar->codec_id, FF_COMPLIANCE_NORMAL) == 1;
        if (audio >= 0) use_mp4 = use_mp4 && avformat_query_codec(mp4, audio_source->ctx->streams[audio]->codecpar->codec_id, FF_COMPLIANCE_NORMAL) == 1;
        Output output;
        check(avformat_alloc_output_context2(&output.ctx, nullptr, use_mp4 ? "mp4" : "matroska", nullptr));
        if (!output.ctx) throw std::runtime_error("Lossless container unavailable");
        output.ctx->interrupt_callback = {Control::interrupt, &control};
        output.ctx->avoid_negative_ts = AVFMT_AVOID_NEG_TS_MAKE_NON_NEGATIVE;
        auto add_stream = [&](const AVStream* source) {
            auto* target = avformat_new_stream(output.ctx, nullptr); if (!target) throw std::bad_alloc();
            check(avcodec_parameters_copy(target->codecpar, source->codecpar));
            target->codecpar->codec_tag = 0; target->time_base = source->time_base;
            target->avg_frame_rate = source->avg_frame_rate; target->disposition = source->disposition;
            check(av_dict_copy(&target->metadata, source->metadata, 0));
            return target->index;
        };
        const int out_video = add_stream(input.ctx->streams[video]);
        const int out_audio = audio < 0 ? -1 : add_stream(audio_source->ctx->streams[audio]);
        av_dict_set(&output.ctx->metadata, "thru3d_mode", mode.c_str(), 0);
        check(avio_open2(&output.ctx->pb, output_path.c_str(), AVIO_FLAG_WRITE, &output.ctx->interrupt_callback, nullptr));
        AVDictionary* options = nullptr;
        if (use_mp4) av_dict_set(&options, "movflags", "+use_metadata_tags", 0);
        const int header = avformat_write_header(output.ctx, &options); av_dict_free(&options); check(header);
        const auto base = input.ctx->streams[video]->time_base;
        auto seek = [](Input& source, int stream, int64_t position) {
            check(av_seek_frame(source.ctx, stream, av_rescale_q(position + source.origin(), AV_TIME_BASE_Q,
                source.ctx->streams[stream]->time_base), AVSEEK_FLAG_BACKWARD));
        };
        seek(input, video, start);
        auto main_packet = packet(), audio_packet = packet();
        if (!main_packet || !audio_packet) throw std::bad_alloc();
        int64_t first = AV_NOPTS_VALUE;
        int read = 0;
        while ((read = av_read_frame(input.ctx, main_packet.get())) >= 0) {
            if (Control::interrupt(&control)) throw std::runtime_error("Clip export cancelled");
            if (main_packet->stream_index == video && (main_packet->flags & AV_PKT_FLAG_KEY) && main_packet->pts != AV_NOPTS_VALUE) {
                first = micros(main_packet->pts, base) - input.origin(); av_packet_unref(main_packet.get()); break;
            }
            av_packet_unref(main_packet.get());
        }
        if (first == AV_NOPTS_VALUE || first >= end) throw std::runtime_error("Recording is too short");
        if (start - first > 10000000) throw std::runtime_error("Keyframe too far from recording start");
        // Read the start again: interleaved audio before the first key packet may belong after its PTS.
        seek(input, video, first);
        if (extra.ctx) seek(extra, audio, first);
        input.prime_video_timestamps(video);
        bool video_done = false, audio_done = audio < 0, video_started = false;
        bool have_main = false, have_audio = false;
        int video_packets = 0;
        int64_t last_video = AV_NOPTS_VALUE;
        auto timestamp = [](Input& source, AVPacket* item, bool decode) {
            const auto value = decode && item->dts != AV_NOPTS_VALUE ? item->dts : item->pts;
            const auto time = micros(value, source.ctx->streams[item->stream_index]->time_base);
            if (time == AV_NOPTS_VALUE) throw std::runtime_error("Clip timestamps unavailable");
            return time - source.origin();
        };
        auto fetch = [&](Input& source, AVPacket* item, bool main) {
            while ((main ? !(video_done && (extra.ctx || audio_done)) : !audio_done)) {
                if (Control::interrupt(&control)) throw std::runtime_error("Clip export cancelled");
                const int code = source.read(item);
                if (code == AVERROR_EOF) { if (main) { video_done = true; if (!extra.ctx) audio_done = true; } else audio_done = true; return false; }
                check(code);
                const bool is_video = main && item->stream_index == video;
                const bool is_audio = item->stream_index == audio && ((!main && extra.ctx) || (main && !extra.ctx));
                if ((!is_video && !is_audio) || (is_video && video_done) || (is_audio && audio_done)) { av_packet_unref(item); continue; }
                const auto time = timestamp(source, item, true);
                if (time >= end) { if (is_video) video_done = true; else audio_done = true; av_packet_unref(item); continue; }
                if (is_video && !video_started) {
                    if (!(item->flags & AV_PKT_FLAG_KEY) || timestamp(source, item, false) != first) { av_packet_unref(item); continue; }
                    video_started = true;
                }
                if (is_audio && timestamp(source, item, false) < first) { av_packet_unref(item); continue; }
                return true;
            }
            return false;
        };
        while (true) {
            if (!have_main) have_main = fetch(input, main_packet.get(), true);
            if (extra.ctx && !have_audio) have_audio = fetch(extra, audio_packet.get(), false);
            if (!have_main && !have_audio) break;
            const bool from_audio = have_audio && (!have_main || timestamp(extra, audio_packet.get(), true) < timestamp(input, main_packet.get(), true));
            auto& source = from_audio ? extra : input;
            auto* item = from_audio ? audio_packet.get() : main_packet.get();
            const bool is_video = !from_audio && item->stream_index == video;
            const auto source_base = source.ctx->streams[item->stream_index]->time_base;
            if (is_video) { ++video_packets; last_video = std::max(last_video, timestamp(source, item, false)); }
            const auto offset = av_rescale_q(first + source.origin(), AV_TIME_BASE_Q, source_base);
            if (item->pts != AV_NOPTS_VALUE) item->pts -= offset;
            if (item->dts != AV_NOPTS_VALUE) item->dts -= offset;
            const int index = is_video ? out_video : out_audio;
            av_packet_rescale_ts(item, source_base, output.ctx->streams[index]->time_base);
            item->stream_index = index; item->pos = -1;
            check(av_interleaved_write_frame(output.ctx, item)); av_packet_unref(item);
            if (from_audio) have_audio = false; else have_main = false;
        }
        if (Control::interrupt(&control)) throw std::runtime_error("Clip export cancelled");
        if (!video_packets || last_video <= first) throw std::runtime_error("Recording is too short");
        check(av_write_trailer(output.ctx)); avio_flush(output.ctx->pb); check(output.ctx->pb->error);
        return "{\"state\":\"saved\",\"extension\":\"" + std::string(use_mp4 ? "mp4" : "mkv") +
            "\",\"start_us\":" + std::to_string(first) + ",\"end_us\":" + std::to_string(last_video) +
            ",\"lead_us\":" + std::to_string(std::max<int64_t>(0, start - first)) + ",\"video_packets\":" + std::to_string(video_packets) + "}";
    } catch (const std::exception& error) { return "{\"state\":\"error\",\"error\":" + json_quote(error.what()) + "}"; }
}
}
