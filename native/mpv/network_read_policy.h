#pragma once
#include <cstdint>
#include <limits>

namespace quest {
// Ordinary head/index seeks do not qualify. Eight alternating jumps between two
// regions >64 MiB apart are only a reason to inspect the MP4 index, never to
// change the read policy without that structural confirmation.
class NetworkSeekPattern {
    uint64_t previous_from = 0, previous_to = 0;
    unsigned turns = 0;
    static uint64_t distance(uint64_t a, uint64_t b) { return a > b ? a - b : b - a; }
public:
    bool observe(uint64_t from, uint64_t to) {
        constexpr uint64_t mib = 1024 * 1024;
        if (from > static_cast<uint64_t>(std::numeric_limits<int64_t>::max()) ||
            to > static_cast<uint64_t>(std::numeric_limits<int64_t>::max()) || distance(from, to) < 64 * mib) {
            turns = 0; return false;
        }
        const bool reverse = turns && distance(from, previous_to) <= 8 * mib && distance(to, previous_from) <= 8 * mib;
        turns = reverse ? turns + 1 : 1;
        previous_from = from; previous_to = to;
        return turns >= 8;
    }
};
}
