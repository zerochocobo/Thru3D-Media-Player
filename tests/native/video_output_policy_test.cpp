#include "../../native/mpv/video_output_policy.h"
#include "../../native/mpv/network_read_policy.h"
#undef NDEBUG // This executable's checks must also run in Release configurations.
#include <cassert>
#include <iostream>
int main() {
    // A seek read with the old playing intent still arms; Godot's pause follows it.
    auto retry = quest::SeekFrameRetry::arm(72199, false, 4, false, true);
    assert(retry.floor == 4);
    assert(quest::SeekFrameRetry::arm(72199, false, 4, true, true).floor == 0); // The layer keeps its own frame.
    assert(quest::SeekFrameRetry::arm(72199, false, 4, false, false).floor == 0); // Software frames are not mapped.
    assert(!retry.ready(4, 3, 4, 2000000)); // Waiting for the seek's restart, even after a mapping failure.
    retry.restarted(2000000);
    retry.restarted(2250000); // Another restart notification does not move the deadline.
    assert(!retry.ready(4, 3, 4, 2499999));
    assert(retry.ready(4, 3, 4, 2500000) && retry.position_ms == 72199 && !retry.exact);
    assert(retry.may_issue(false, false, 4, 3, 4, 2500000)); // Paused by the time the retry is due.
    assert(!retry.may_issue(true, false, 4, 3, 4, 2500000)); // Playing decodes fresh frames instead.
    assert(!retry.may_issue(false, true, 4, 3, 4, 2500000)); // A queued user seek replaces the retry.
    assert(!retry.ready(4, 4, 4, 2500000)); // A fresh native frame supersedes the lost one.
    assert(!retry.ready(4, 3, 3, 2500000)); // A failure from a prior seek cannot arm this one.
    assert(!retry.ready(5, 3, 4, 2500000)); // A newer seek supersedes the retry.
    retry = {};
    assert(!retry.ready(5, 3, 5, 3500000)); // The internal retry cannot arm another retry.
    using quest::layer_video_chain_failed;
    const auto failure = "Could not initialize video chain.\n";
    assert(layer_video_chain_failed(true, false, true, "cplayer", failure));
    assert(!layer_video_chain_failed(false, false, true, "cplayer", failure));
    assert(!layer_video_chain_failed(true, true, true, "cplayer", failure));
    assert(!layer_video_chain_failed(true, false, false, "cplayer", failure));
    assert(!layer_video_chain_failed(true, false, true, "ad", failure));
    assert(!layer_video_chain_failed(true, false, true, "cplayer", "audio output initialization failed"));
    assert(!layer_video_chain_failed(true, false, true, "vd", "Failed to create CUDA device"));
    assert(!layer_video_chain_failed(true, false, true, "cplayer", "Video: no video"));
    quest::NetworkSeekPattern normal;
    assert(!normal.observe(0, 29000000000ULL));
    assert(!normal.observe(29000004096ULL, 48));
    for (int i = 0; i < 100; ++i) assert(!normal.observe(i * 32000, i * 32000 + 4096));
    quest::NetworkSeekPattern broken;
    for (int i = 0; i < 7; ++i) assert(!broken.observe(i % 2 ? 116000000 : 48000, i % 2 ? 48000 : 116000000));
    assert(broken.observe(116000000, 48000));
    quest::NetworkSeekPattern forward;
    for (uint64_t i = 0; i < 20; ++i) assert(!forward.observe(i * 100000000, (i + 1) * 100000000));
    for (uint64_t span : {512ULL, 8192ULL, 4ULL * 1024 * 1024}) {
        quest::NetworkSeekPattern small;
        for (int i = 0; i < 7; ++i) assert(!small.observe(i % 2 ? span : 0, i % 2 ? 0 : span));
        assert(small.observe(span, 0));
    }
    quest::NetworkSeekPattern stationary;
    for (int i = 0; i < 20; ++i) assert(!stationary.observe(100, 100));
    quest::NetworkSeekPattern after_jump;
    for (int i = 0; i < 7; ++i) assert(!after_jump.observe(i % 2 ? 4096 : 0, i % 2 ? 0 : 4096));
    after_jump = quest::NetworkSeekPattern{};
    for (int i = 0; i < 7; ++i) assert(!after_jump.observe(i % 2 ? 4096 : 0, i % 2 ? 0 : 4096));
    assert(after_jump.observe(4096, 0));
    std::cout << "Video output/network seek policy checks passed\n";
}
