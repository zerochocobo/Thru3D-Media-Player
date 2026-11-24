#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>

namespace quest {

/** 2D->3D flat frame edges (optional): at the picture's left and right edges the near map is held
 * inside a cone around the screen plane that opens with the distance from the edge,
 *     |near - plane| <= G * d,   G = 2 * kStretch / shift per picture width,
 * so the parallax reaches zero at the frame and nowhere stretches the picture by more than kStretch.
 *
 * Why: content off the plane at the frame is the stereoscopic window violation (in front of the
 * screen, the frame cuts it at a different place in each eye: stereopsis against occlusion), and
 * with one picture for both eyes also a smear, since an eye reads past the frame and the edge column
 * repeats, as wide as the parallax, different on every row and moving with the depth. Productions
 * mask the frame (floating windows); interactive renderers bring parallax to zero at the border
 * (Dynparity, Comput. Anim. Virtual Worlds 2022, for geometry in front of the plane).
 *
 * How this one differs from a fixed fade band (parallax times a ramp of fixed width): the limit is
 * a bound, not a gain. A row whose edge already lies on the plane is not touched; the reach grows
 * with how far the edge content is off the plane and with the strength, and the stretch it adds is
 * the same bounded amount everywhere instead of growing with both. It is a spatially varying range
 * limit in the sense of nonlinear disparity mapping (Lang et al., SIGGRAPH 2010), applied to the
 * map, so every reader of the near texture follows. Both sides of the plane are limited: behind it
 * there is no window violation, but no pixels beyond the frame either. */
constexpr float kNearEdgeStretch = 0.10f;

/** near: w-wide rows; content {cx, cy, cw, ch} in texels. shift: the parallax between nearest and
 * farthest as a fraction of the picture width. plane: the near value on the screen plane (the
 * convergence). The cone's corner is rounded (a p = 4 soft clamp), so no crease shows where it bites. */
inline void near_edge_fade(float* near, int w, int cx, int cy, int cw, int ch, float shift, float plane) {
    if (!(shift > 0.f) || cw < 2) return;
    const float slope = 2.f * kNearEdgeStretch / (shift * cw); // near per texel
    for (int i = 0; i < cw / 2; ++i) {
        const float limit = slope * (i + 0.5f); // texel centre from the edge
        if (limit >= 2.5f) break; // |near - plane| <= 1: under 1% left to change
        for (int y = cy; y < cy + ch; ++y) {
            float* row = near + static_cast<size_t>(y) * w;
            for (const int x : {cx + i, cx + cw - 1 - i}) {
                const float off = row[x] - plane, r = off / limit, r2 = r * r;
                row[x] = plane + off / std::sqrt(std::sqrt(1.f + r2 * r2));
            }
        }
    }
}

} // namespace quest
