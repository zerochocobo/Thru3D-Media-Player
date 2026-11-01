#pragma once
#include <array>
#include <stdexcept>
#include <utility>

namespace quest {
// Top-origin pixel coordinates, matching the still RGBA and RF buffers.
inline std::pair<int, int> photo_rotated_pixel(int x, int y, int w, int h, int turns) {
    switch (turns) {
        case 0: return {x, y};
        case 1: return {h - 1 - y, x};
        case 2: return {w - 1 - x, h - 1 - y};
        case 3: return {y, w - 1 - x};
        default: throw std::invalid_argument("Invalid photo quarter turn");
    }
}
inline std::array<float, 4> photo_rotated_rect(const std::array<float, 4>& r, int turns) {
    switch (turns) {
        case 0: return r;
        case 1: return {{1.f - r[1] - r[3], r[0], r[3], r[2]}};
        case 2: return {{1.f - r[0] - r[2], 1.f - r[1] - r[3], r[2], r[3]}};
        case 3: return {{r[1], 1.f - r[0] - r[2], r[3], r[2]}};
        default: throw std::invalid_argument("Invalid photo quarter turn");
    }
}
}
