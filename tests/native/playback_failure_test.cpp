#include "../../native/mpv/playback_failure.h"
#include <cassert>
#include <iostream>

int main() {
    using namespace quest;
    assert(playback_end_failure(-13, {}).reason == "unknown");
    assert(playback_end_failure(-17, {}).reason == "unknown_format");
    assert(playback_end_failure(-16, {}).reason == "nothing_to_play");
    const auto decoder = playback_log_failure("vd", "Error opening decoder with private address https://secret/video");
    assert(decoder.reason == "decoder_failed" && decoder.detail.find("secret") == std::string::npos);
    assert(playback_end_failure(-16, decoder).reason == "decoder_failed");
    assert(playback_end_failure(-15, decoder).reason == "video_output_failed");
    assert(playback_end_failure(-14, decoder).reason == "audio_output_failed");
    assert(playback_log_failure("sub", "Timeout downloading optional subtitles").reason.empty());
    assert(playback_log_failure("ad", "Error opening decoder").reason.empty());
    assert(playback_log_failure("vo/gpu", "Timeout initializing video output").reason.empty());
    const auto timeout = playback_log_failure("stream", "Read timed out at https://secret/video");
    assert(timeout.reason == "network_timeout" && timeout.detail.find("secret") == std::string::npos);
    assert(playback_end_failure(-17, timeout).reason == "unknown_format");
    assert(playback_end_failure(-13, timeout).reason == "network_timeout");
    assert(playback_exception_failure("MPV video output format did not become ready within 15 seconds").reason == "output_timeout");
    assert(playback_log_failure("ffmpeg", "SSL peer certificate cannot be authenticated").reason == "tls_failed");
    std::cout << "Playback failure native checks passed: 15\n";
}
