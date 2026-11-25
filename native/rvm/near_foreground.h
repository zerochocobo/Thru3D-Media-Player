#pragma once

#include <algorithm>
#include <array>
#include <cmath>

namespace quest {

/** 2D->3D foreground scale: a curve on the near map that shares the depth between near and far
 * (iw3's "foreground scale"). A power curve n^p, held so the screen plane stays where it is and
 * the map stays within [0, 1]:
 *     f(n) = plane + (n^p - plane^p) * s,   s = min((1 - plane) / (1 - plane^p), plane / plane^p)
 * p > 1 spreads the near end (faces and things in front get more layers) and flattens the
 * background; p < 1 the other way round. p = 1 is the model's own map.
 *
 * As a lookup over the 8-bit map, applied where the map is limited (render_bridge limited_near):
 * every reader of the near texture follows, and a held (paused) frame is redrawn with it. */
inline float near_foreground_exponent(float scale) { return std::exp2(std::clamp(scale, -1.f, 1.f)); }

inline float near_foreground(float n, float exponent, float plane) {
    if (!(exponent > 0.f) || exponent == 1.f || !(plane > 0.f && plane < 1.f)) return n;
    const float pp = std::pow(plane, exponent);
    const float s = std::min((1.f - plane) / (1.f - pp), plane / pp);
    return std::clamp(plane + (std::pow(std::clamp(n, 0.f, 1.f), exponent) - pp) * s, 0.f, 1.f);
}

/** The curve over the 256 map levels (identity when exponent is 1). */
inline std::array<float, 256> near_foreground_table(float exponent, float plane) {
    std::array<float, 256> table{};
    for (int i = 0; i < 256; ++i) table[i] = near_foreground(i / 255.f, exponent, plane);
    return table;
}

} // namespace quest
