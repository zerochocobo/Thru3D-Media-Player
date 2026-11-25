#pragma once
#include <cstdint>
#include <string_view>

namespace quest {
enum class SourceSlotPhase { free, rendering, ready, acquired, retiring };

// acquire_frame only offers tokens newer than the last acquired token. Return skipped
// decoder images to MediaCodec as soon as their existing producer fences complete.
template<class Slots>
unsigned retire_superseded_decoder_images(Slots& slots, uint64_t acquired_token) {
    unsigned retired = 0;
    for (auto& slot : slots) {
        if (slot.phase == SourceSlotPhase::ready && slot.image && slot.token < acquired_token) {
            slot.phase = SourceSlotPhase::retiring;
            ++retired;
        }
    }
    return retired;
}

// The producer may overwrite its own RGBA texture in command order. Returning a
// decoder image to MediaCodec also requires its GPU read to have finished.
template<class Slots, class ImageReady>
auto writable_source_slot(Slots& slots, ImageReady image_ready, bool& waiting) -> typename Slots::value_type* {
    waiting = false;
    typename Slots::value_type* oldest = nullptr;
    for (auto& slot : slots) {
        if (slot.phase == SourceSlotPhase::free) return &slot;
        if (slot.phase == SourceSlotPhase::ready && (!oldest || slot.token < oldest->token))
            oldest = &slot;
    }
    if (oldest && oldest->image && !image_ready(*oldest)) {
        waiting = true;
        return nullptr;
    }
    return oldest;
}

// Decoder OES sampling converts YUV to RGB, but cannot tone-map PQ/HLG or map
// their wide gamut into the SDR eye-buffer contract. Profile 5 additionally
// needs the existing RPU/IPT conversion, even without a container transfer tag.
inline bool needs_sdr_color_conversion(std::string_view transfer, bool dolby_profile5) {
    return dolby_profile5 || transfer == "pq" || transfer == "hlg" ||
        transfer == "smpte2084" || transfer == "arib-std-b67";
}

inline bool can_export_decoder_image(bool requested, bool redraw, int rotation,
                                     bool hardware, bool color_conversion) {
    return requested && !redraw && rotation == 0 && hardware && !color_conversion;
}

// Only a failed hardware render during a paused seek can trigger a retry. Give MPV
// time to deliver a fresh frame after an invalid retained redraw.
struct SeekFrameRetry {
    int64_t position_ms = -1;
    bool exact = false;
    uint64_t floor = 0;
    int64_t retry_after_us = -1;

    // Godot queues the seek before pausing, so the play intent read with the seek
    // can still be the old one. Arm regardless; may_issue checks the latest intent.
    static SeekFrameRetry arm(int64_t position_ms, bool exact, uint64_t floor, bool layer, bool hardware) {
        return {position_ms, exact, !layer && hardware ? floor : 0};
    }

    void restarted(int64_t now_us) {
        if (floor && retry_after_us < 0) retry_after_us = now_us + 500000;
    }

    bool ready(uint64_t active_floor, uint64_t published_epoch, uint64_t failed_floor, int64_t now_us) const {
        return floor && floor == active_floor && floor == failed_floor && published_epoch < floor &&
            retry_after_us >= 0 && now_us >= retry_after_us;
    }

    // A playing source delivers fresh frames itself; a newer seek replaces this one.
    bool may_issue(bool desired_play, bool seek_pending, uint64_t active_floor, uint64_t published_epoch,
                   uint64_t failed_floor, int64_t now_us) const {
        return !desired_play && !seek_pending && ready(active_floor, published_epoch, failed_floor, now_us);
    }
};

inline bool layer_video_chain_failed(bool layer, bool software_layer, bool error,
                                     std::string_view prefix, std::string_view message) {
    return layer && !software_layer && error && prefix == "cplayer" &&
        message.find("Could not initialize video chain.") != std::string_view::npos;
}

// MediaCodec refused the stream (H.264 High 10 on Quest) and MPV decodes it in software:
// frames the layer's decoder surface cannot take.
inline bool layer_software_decoder(bool layer, bool software_layer, std::string_view prefix,
                                   std::string_view message) {
    return layer && !software_layer && prefix == "vd" &&
        message.find("Using software decoding.") != std::string_view::npos;
}

// A file with no audio has nothing left once its software frames are refused: it ends as
// "nothing to play" before the video chain error or a snapshot moves it off the layer.
inline bool layer_end_is_software_fallback(bool layer, bool software_layer, bool software_decoder,
                                           bool nothing_to_play) {
    return layer && !software_layer && software_decoder && nothing_to_play;
}
}
