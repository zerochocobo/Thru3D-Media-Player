#pragma once
#include <string>

namespace quest {
struct PlaybackFailure {
    std::string reason, stage, detail;
};

// Only fixed descriptions cross JNI. Log text may contain signed URLs or credentials.
inline PlaybackFailure playback_log_failure(const std::string& prefix, const std::string& text) {
    if (prefix.find("sub") != std::string::npos || prefix.find("audio") != std::string::npos || prefix == "ad") return {};
    const bool network = prefix.find("stream") == 0 || prefix.find("curl") == 0 || prefix.find("ffmpeg") == 0;
    if (network && (text.find("certificate verification failed") != std::string::npos || text.find("SSL peer certificate") != std::string::npos))
        return {"tls_failed", "reading", "TLS certificate verification failed"};
    if (network && (text.find("timed out") != std::string::npos || text.find("Timeout") != std::string::npos))
        return {"network_timeout", "reading", "Network read timed out"};
    if ((prefix == "vd" || prefix == "cplayer" || prefix.find("vd/") == 0) &&
        (text.find("Error opening decoder") != std::string::npos || text.find("Failed to initialize a video decoder") != std::string::npos))
        return {"decoder_failed", "decoding", "Video decoder could not be started"};
    return {};
}

inline PlaybackFailure playback_end_failure(int code, const PlaybackFailure& hint) {
    if (code == -14) return {"audio_output_failed", "output", "Audio output initialization failed"};
    if (code == -15) return {"video_output_failed", "output", "Video output initialization failed"};
    if (code == -16) return hint.reason == "decoder_failed" ? hint : PlaybackFailure{"nothing_to_play", "parsing", "No playable audio or video streams"};
    if (code == -17) return {"unknown_format", "parsing", "Media format could not be determined or the file is damaged"};
    if (!hint.reason.empty()) return hint;
    return {"unknown", "opening", ""};
}

// The shared GPU slots hold at most 8192 on a side and 8192x4320 pixels, whatever the decoder.
constexpr long long kSourceMaxSide = 8192, kSourceMaxPixels = 8192LL * 4320;
inline bool source_dimensions_supported(long long width, long long height) {
    return width > 0 && height > 0 && width <= kSourceMaxSide && height <= kSourceMaxSide && width * height <= kSourceMaxPixels;
}
constexpr const char* kSourceDimensionsExceeded = "MPV source dimensions exceed the current GPU slot contract";

// A splice (an inserted HLS segment, joined transport streams) can change the decoded size or
// rotation in the middle of a file. A session's GPU slots keep one format, so the player reopens
// just past the change instead of ending playback.
constexpr const char* kSourceSizeChanged = "MPV midstream size change requires a new format generation";
constexpr const char* kSourceRotationChanged = "MPV midstream rotation change requires a new format generation";
constexpr const char* kSourceFrameFormatChanged = "MPV transformed source needs an explicit format mapping before publication";
inline bool source_format_changed(const std::string& text) {
    return text == kSourceSizeChanged || text == kSourceRotationChanged || text == kSourceFrameFormatChanged;
}

// Some decoders reject the first packets of the new size instead (Quest 2, OMX.qcom.video.decoder.avc):
// after three errors MPV restarts decoding, the decoder images still queued for display are gone,
// and rendering one fails. The player reopens the same way.
constexpr const char* kSourceFrameLost = "MPV immutable color render: something happened";
inline const char* render_failure_reason(const std::string& text) {
    return source_format_changed(text) ? "source_format_changed" : text == kSourceFrameLost ? "source_frame_lost" : "video_output_failed";
}

inline PlaybackFailure playback_exception_failure(const std::string& text) {
    if (source_format_changed(text))
        return {"source_format_changed", "output", ""};
    if (text == "MPV video output format did not become ready within 15 seconds")
        return {"output_timeout", "output", ""};
    if (text == kSourceDimensionsExceeded)
        return {"resolution_unsupported", "decoding", ""};
    if (text == "MPV shared renderer failed to initialize")
        return {"video_output_failed", "output", ""};
    return {"unknown", "opening", ""};
}
}
