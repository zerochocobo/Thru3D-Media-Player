#pragma once
#include <algorithm>
#include <cmath>
#include <stdexcept>
#include <vector>

namespace quest {
// Still-photo range: cap the 100% base first, then apply strength. Capping after strength
// made large photographs hit 96px before 100%, leaving the 100..200% rail ineffective.
// Video retains its own realtime cap. Fractional strengths must not snap to a 2px minimum.
inline float photo_half_shift(int width, float strength) {
    if (width < 1 || !std::isfinite(strength) || strength < 0.f || strength > 2.f)
        throw std::invalid_argument("Invalid photo disparity strength");
    return std::max(2.f, std::min(96.f, width * 0.035f)) * strength * 0.5f;
}

// Still-image normalization. Only the content rectangle contributes to the band or
// foreground dilation; the surrounding padding is extended from its nearest content
// pixel so linear sampling cannot pull artificial depth into the picture's edges.
// Constant/invalid depth stays on the screen plane. Throws for an invalid rectangle.
void photo_near_map(const float* inverse, int width, int height,
                    int x, int y, int content_width, int content_height, float* near);

// Disparity-gradient limit for a still about to be warped: near may fall by at most
// 0.9 / half_columns per model column, where half_columns is one eye's shift in model columns
// at the strength being rendered. The shared warp fills a disocclusion by the inverse warp at
// the hole's own depth; behind a sharper fall that lookup reaches back across the silhouette and
// repeats the subject's contour (hair, face, arms floating outside). Within the limit the lookup
// stays monotone and the background beside the subject is stretched instead. Header-only so the
// render bridge (a separate library) and the host tests share it. Padding is re-extended.
inline void photo_limit_gradient(float* near, int width, int height,
                                 int x, int y, int cw, int ch, float half_columns) {
    if (!near || width < 1 || height < 1 || x < 0 || y < 0 || cw < 1 || ch < 1 ||
        x > width - cw || y > height - ch || !std::isfinite(half_columns))
        throw std::invalid_argument("Invalid photo gradient limit");
    if (half_columns <= 0.f) return;
    const float slope = 0.9f / half_columns;
    const int reach = static_cast<int>(std::ceil(1.f / slope));
    std::vector<float> line(static_cast<size_t>(cw));
    for (int row = y; row < y + ch; ++row) {
        float* r = near + static_cast<size_t>(row) * width + x;
        std::copy(r, r + cw, line.begin());
        for (int col = 0; col < cw; ++col)
            for (int d = 1; d <= reach; ++d) {
                const float fall = line[col] - slope * d;
                if (fall <= 0.f) break;
                if (col - d >= 0) r[col - d] = std::max(r[col - d], fall);
                if (col + d < cw) r[col + d] = std::max(r[col + d], fall);
            }
    }
    for (int row = 0; row < height; ++row) for (int col = 0; col < width; ++col)
        if (row < y || row >= y + ch || col < x || col >= x + cw)
            near[static_cast<size_t>(row) * width + col] =
                near[static_cast<size_t>(std::clamp(row, y, y + ch - 1)) * width + std::clamp(col, x, x + cw - 1)];
}
}
