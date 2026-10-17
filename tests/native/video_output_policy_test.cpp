#include "../../native/mpv/video_output_policy.h"
#include "../../native/mpv/network_read_policy.h"
#undef NDEBUG // This executable's checks must also run in Release configurations.
#include <cassert>
#include <iostream>
int main() {
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
    std::cout << "Video output/network seek policy: 138 checks passed\n";
}
