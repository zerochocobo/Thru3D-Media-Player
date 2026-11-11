#pragma once
#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <stdexcept>

namespace thru::image {
// Same aspect fit and repeated edge as the video model input. Only the content
// rectangle contributes to normalization. Transparent pixels use neutral grey.
inline std::array<int, 4> animation_input(const uint8_t* rgba, size_t bytes, int sw, int sh,
                                         float* rgb, size_t floats, int w, int h) {
    if (!rgba || !rgb || sw < 1 || sh < 1 || sw > 2048 || sh > 2048 ||
        w < 1 || h < 1 || w > 1024 || h > 1024 ||
        bytes != size_t(sw) * sh * 4 || floats != size_t(w) * h * 3)
        throw std::invalid_argument("Invalid animation depth input");
    const double scale = std::min(double(w) / sw, double(h) / sh);
    const int cw = std::clamp(int(std::lround(sw * scale)), 1, w);
    const int ch = std::clamp(int(std::lround(sh * scale)), 1, h);
    const int x = (w - cw) / 2, y = (h - ch) / 2;
    const size_t plane = size_t(w) * h;
    for (int j = 0; j < h; ++j) {
        const double sy = std::clamp((std::clamp(j - y, 0, ch - 1) + 0.5) * sh / ch - 0.5, 0.0, double(sh - 1));
        const int y0 = int(sy), y1 = std::min(y0 + 1, sh - 1);
        const float fy = float(sy - y0);
        for (int i = 0; i < w; ++i) {
            const double sx = std::clamp((std::clamp(i - x, 0, cw - 1) + 0.5) * sw / cw - 0.5, 0.0, double(sw - 1));
            const int x0 = int(sx), x1 = std::min(x0 + 1, sw - 1);
            const float fx = float(sx - x0);
            for (int c = 0; c < 3; ++c) {
                auto pixel = [&](int px, int py) {
                    const auto p = rgba + (size_t(py) * sw + px) * 4;
                    const float a = p[3] / 255.f;
                    return p[c] / 255.f * a + 0.5f * (1.f - a);
                };
                const float top = pixel(x0, y0) * (1.f - fx) + pixel(x1, y0) * fx;
                const float bottom = pixel(x0, y1) * (1.f - fx) + pixel(x1, y1) * fx;
                rgb[size_t(c) * plane + size_t(j) * w + i] = top * (1.f - fy) + bottom * fy;
            }
        }
    }
    return {x, y, cw, ch};
}
}
