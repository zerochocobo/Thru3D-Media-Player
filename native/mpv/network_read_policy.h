#pragma once
#include <cstdint>
#include <limits>

namespace quest {
// A normal head/index round trip does not qualify. Eight alternating stream seeks
// are only a reason to inspect the MP4 index, never to
// change the read policy without that structural confirmation.
class NetworkSeekPattern {
    bool previous_forward = false;
    unsigned turns = 0;
public:
    bool observe(uint64_t from, uint64_t to) {
        if (from > static_cast<uint64_t>(std::numeric_limits<int64_t>::max()) ||
            to > static_cast<uint64_t>(std::numeric_limits<int64_t>::max()) || from == to) {
            turns = 0; return false;
        }
        const bool forward = from < to;
        const bool reverse = turns && forward != previous_forward;
        turns = reverse ? turns + 1 : 1;
        previous_forward = forward;
        return turns >= 8;
    }
};
}
