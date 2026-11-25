#include "../../native/mpv/log_module_trail.h"
#undef NDEBUG // This executable's checks must also run in Release configurations.
#include <cassert>
#include <iostream>
int main() {
    quest::LogModuleTrail trail;
    const std::string unconfirmed = ",\"decoder\":\"unknown\",\"decoder_observed_ms\":-1,\"mediacodec_started_ms\":-1";
    assert(trail.json_fields(5000) == ",\"recent_modules\":[],\"last_log_ms\":-1" + unconfirmed);
    trail.observe("cplayer", "", 1000);
    trail.observe("ao/aaudio", "", 2000);
    trail.observe("ao/aaudio", "", 3000); // Repeats keep one entry but move the last-log time.
    assert(trail.json_fields(53000) == ",\"recent_modules\":[\"cplayer\",\"ao/aaudio\"],\"last_log_ms\":50" + unconfirmed);
    for (const char* module : {"vd", "ffmpeg/demuxer", "stream", "demux", "vo/libmpv"}) trail.observe(module, "", 4000);
    // Only the six most recent changes remain, oldest first.
    assert(trail.json_fields(4000) ==
           ",\"recent_modules\":[\"ao/aaudio\",\"vd\",\"ffmpeg/demuxer\",\"stream\",\"demux\",\"vo/libmpv\"],\"last_log_ms\":0" + unconfirmed);
    trail.observe("vd", "Trying hardware decoding via hevc_mediacodec-mediacodec.", 6000);
    trail.observe("ffmpeg/video", "hevc_mediacodec: MediaCodec started successfully: codec = c2.qti.hevc.decoder, ret = 0", 7000);
    trail.observe("vd", "Selected decoder: hevc - HEVC (High Efficiency Video Coding)", 8000);
    trail.observe("ad", "Using software decoding.", 9000);
    assert(trail.json_fields(10000).find("\"decoder\":\"unknown\",\"decoder_observed_ms\":-1,\"mediacodec_started_ms\":7") != std::string::npos);
    trail.observe("vd", "Using hardware decoding (mediacodec).", 11000);
    assert(trail.json_fields(12000).find("\"decoder\":\"hardware\",\"decoder_observed_ms\":11") != std::string::npos);
    trail.observe("vd", "Using software decoding.", 13000);
    assert(trail.json_fields(14000).find("\"decoder\":\"software\",\"decoder_observed_ms\":13") != std::string::npos);
    // Prefixes are module names: anything else (quotes, spaces, paths' characters) cannot leak through.
    assert(quest::LogModuleTrail::clean("ffmpeg/Video") == "ffmpeg/video");
    assert(quest::LogModuleTrail::clean("a\"b c\\d:e") == "a?b?c?d?e");
    assert(quest::LogModuleTrail::clean(nullptr) == "?" && quest::LogModuleTrail::clean("") == "?");
    assert(quest::LogModuleTrail::clean("abcdefghijklmnopqrstuvwxyz0123").size() == quest::LogModuleTrail::kPrefix);
    // A second trail in the same record names its fields with a prefix.
    quest::LogModuleTrail core;
    core.observe("ao/aaudio", "", 1000);
    assert(core.json_fields(3000, "core_") == ",\"core_recent_modules\":[\"ao/aaudio\"],\"core_last_log_ms\":2,\"core_decoder\":\"unknown\","
        "\"core_decoder_observed_ms\":-1,\"core_mediacodec_started_ms\":-1");
    quest::ControlCall call;
    assert(call.json_fields(5000) == ",\"control_call\":\"setup\",\"control_call_ms\":-1");
    call.enter("snapshot", 2000);
    assert(call.json_fields(14000) == ",\"control_call\":\"snapshot\",\"control_call_ms\":12");
    call.enter("wait_event", 15000);
    assert(call.json_fields(15000) == ",\"control_call\":\"wait_event\",\"control_call_ms\":0");
    std::cout << "MPV log module trail checks passed\n";
}
