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

inline PlaybackFailure playback_exception_failure(const std::string& text) {
    if (text == "MPV video output format did not become ready within 15 seconds")
        return {"output_timeout", "output", ""};
    if (text == "MPV shared renderer failed to initialize")
        return {"video_output_failed", "output", ""};
    return {"unknown", "opening", ""};
}
}
