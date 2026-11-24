#pragma once

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdlib>
#include <vector>

namespace quest {

/** Black bars burned into the video frame (a 2.39:1 film in a 16:9 HDR WEB-DL, a portrait video
 * pillarboxed in a fullscreen web page), found in the depth model input. ZipDepth reads a black band
 * as a near object: the bar takes the top of the near band, leaves a false near strip along the
 * picture edge and compresses the picture's relief. The render bridge already repeats the edge for
 * its own aspect letterbox; this does the same for bars inside the frame, and gives the picture
 * rectangle to the stabilizer's band.
 *
 * A line with no pixel above kBlack in a frame is dark. Bars apply once they have faced each other
 * for kHold frames in a row (about a quarter of a second: shadows that flicker at both sides of a
 * dark scene never get there), and stop as soon as a pixel of them lights. An all-black line holds
 * no picture to lose, so a dark scene that is taken for bars only gets its black edge repeated;
 * once found, the bars do not widen with a darker scene, which would move the band's area from
 * frame to frame. Bars must face each other (a one-sided dark band is sky or shadow), and the
 * picture keeps at least kMinPicture of the input; otherwise nothing is cropped. Not thread-safe. */
class PictureBars {
public:
    static constexpr float kBlack = 0.02f;      // model input luma, 0-1 (~5/255); bars measure 0
    static constexpr float kMinPicture = 0.35f;
    static constexpr int kMinBar = 2;
    static constexpr int kHold = 8;             // model inputs (~30/s video, ~15/s web)

    /** rgb: float CHW in [0, 1], w x h; filled in place. Returns the picture {x, y, width, height}. */
    std::array<int, 4> apply(float* rgb, int w, int h) {
        const size_t n = static_cast<size_t>(w) * h;
        std::vector<float> row(h, 0.f), col(w, 0.f);
        for (int y = 0; y < h; ++y) for (int x = 0; x < w; ++x) {
            const size_t p = static_cast<size_t>(y) * w + x;
            const float luma = 0.299f * rgb[p] + 0.587f * rgb[n + p] + 0.114f * rgb[2 * n + p];
            row[y] = std::max(row[y], luma); col[x] = std::max(col[x], luma);
        }
        if (w != w_ || h != h_) { w_ = w; h_ = h; rows_ = cols_ = Side(); }
        int y0 = 0, y1 = h, x0 = 0, x1 = w;
        side(row, rows_, &y0, &y1);
        side(col, cols_, &x0, &x1);
        rect_ = {x0, y0, x1 - x0, y1 - y0};
        if (y0 > 0 || y1 < h || x0 > 0 || x1 < w) fill(rgb, w, h);
        return rect_;
    }
    const std::array<int, 4>& picture() const { return rect_; }

private:
    int w_ = 0, h_ = 0;
    std::array<int, 4> rect_{{0, 0, 0, 0}};
    struct Side { int before = 0, after = 0, age = 0; }; // bars of one axis (0: none), frames they have lasted
    Side rows_, cols_;

    /** One axis: [*first, *last) is the picture. A dark scene widens the dark band into the picture
     * (fades, night shots): the bars only ever narrow while they last, at once when a line lights, and
     * an all-dark frame keeps them. A frame without bars forgets them. */
    static void side(const std::vector<float>& peak, Side& held, int* first, int* last) {
        const int n = static_cast<int>(peak.size());
        int a = 0, b = n;
        while (a < n && peak[a] < kBlack) ++a;
        while (b > a && peak[b - 1] < kBlack) --b;
        if (a < n) {
            // The outermost lit line is a bar/picture blend, so one more line goes to each bar.
            if (a > 0) ++a;
            if (b < n) --b;
            const int before = a, after = n - std::max(a, b);
            if (before < kMinBar || after < kMinBar) { held = Side(); return; }
            // Each bar keeps its own narrowest size: the two need not match to the line.
            held.before = held.before > 0 ? std::min(held.before, before) : before;
            held.after = held.after > 0 ? std::min(held.after, after) : after;
        }
        if (held.before == 0) return;
        // Bars face each other. While a dark scene still darkens the picture's own lines next to one
        // bar, those lines are picture: both sides use the narrower size (nothing of the picture is lost).
        int lo = held.before, hi = held.after;
        if (std::abs(lo - hi) > 2 + std::max(lo, hi) / 5) lo = hi = std::min(lo, hi);
        if (n - lo - hi < kMinPicture * n) { held = Side(); return; }
        if (held.age < kHold && ++held.age < kHold) return;
        *first = lo; *last = n - hi;
    }
    void fill(float* rgb, int w, int h) const {
        const size_t n = static_cast<size_t>(w) * h;
        const int x0 = rect_[0], y0 = rect_[1], x1 = rect_[0] + rect_[2], y1 = rect_[1] + rect_[3];
        for (int c = 0; c < 3; ++c) {
            float* plane = rgb + c * n;
            for (int y = 0; y < h; ++y) {
                const int sy = std::clamp(y, y0, y1 - 1);
                float* line = plane + static_cast<size_t>(y) * w;
                if (sy != y) std::copy(plane + static_cast<size_t>(sy) * w, plane + static_cast<size_t>(sy + 1) * w, line);
                for (int x = 0; x < x0; ++x) line[x] = line[x0];
                for (int x = x1; x < w; ++x) line[x] = line[x1 - 1];
            }
        }
    }
};

} // namespace quest
