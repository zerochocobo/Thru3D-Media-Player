#include "../../native/mpv/log_module_trail.h"
#undef NDEBUG // This executable's checks must also run in Release configurations.
#include <cassert>
#include <iostream>
int main() {
    quest::LogModuleTrail trail;
    assert(trail.json_fields(5000) == ",\"recent_modules\":[],\"last_log_ms\":-1");
    trail.observe("cplayer", 1000);
    trail.observe("ao/aaudio", 2000);
    trail.observe("ao/aaudio", 3000); // Repeats keep one entry but move the last-log time.
    assert(trail.json_fields(53000) == ",\"recent_modules\":[\"cplayer\",\"ao/aaudio\"],\"last_log_ms\":50");
    for (const char* module : {"vd", "ffmpeg/demuxer", "stream", "demux", "vo/libmpv"}) trail.observe(module, 4000);
    // Only the six most recent changes remain, oldest first.
    assert(trail.json_fields(4000) ==
           ",\"recent_modules\":[\"ao/aaudio\",\"vd\",\"ffmpeg/demuxer\",\"stream\",\"demux\",\"vo/libmpv\"],\"last_log_ms\":0");
    // Prefixes are module names: anything else (quotes, spaces, paths' characters) cannot leak through.
    assert(quest::LogModuleTrail::clean("ffmpeg/Video") == "ffmpeg/video");
    assert(quest::LogModuleTrail::clean("a\"b c\\d:e") == "a?b?c?d?e");
    assert(quest::LogModuleTrail::clean(nullptr) == "?" && quest::LogModuleTrail::clean("") == "?");
    assert(quest::LogModuleTrail::clean("abcdefghijklmnopqrstuvwxyz0123").size() == quest::LogModuleTrail::kPrefix);
    std::cout << "MPV log module trail checks passed\n";
}
