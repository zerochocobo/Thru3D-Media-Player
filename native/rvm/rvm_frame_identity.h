#pragma once
#include <cstdint>

namespace quest {
// Generation validation belongs to the owning runtime. Within that generation only an explicit
// reset may replay exactly the same source frame and timestamp (paused effect refresh).
constexpr bool accepts_rvm_frame(int64_t last_frame, int64_t last_pts, int64_t frame, int64_t pts, bool reset) {
    return frame >= 0 && pts >= 0 && (frame > last_frame || (reset && frame == last_frame && pts == last_pts));
}
}
