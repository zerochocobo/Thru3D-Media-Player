#pragma once

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdlib>
#include <vector>

namespace quest {

/** Black bars burned into the video frame (a 2.39:1 film in a 16:9 HDR WEB-DL), found in the depth
 * model input. ZipDepth reads a black band as a near object: the bar takes the top of the near band,
 * leaves a false near strip along the picture edge and compresses the picture's relief. The render
 * bridge already repeats the edge for its own aspect letterbox; this does the same for bars inside
 * the frame, and gives the picture rectangle to the stabilizer's band.
 *
 * Burned-in bars are digital black in every frame, but a dark film can hold black sides or a black
 * opening for many seconds, so darkness alone does not make a bar: a line is a bar when it has not
 * been lit since playback began (after kWarm frames) or for the last kSettle frames. Bars must face
 * each other with about the same size, and the picture keeps at least kMinPicture of the input;
 * otherwise nothing is cropped. Frames are model inputs (~30/s). Not thread-safe. */
class PictureBars {
public:
    static constexpr float kBlack = 0.02f;      // model input luma, 0-1 (~5/255); bars measure 0
    static constexpr int kWarm = 300, kSettle = 1800; // ~10 s before any crop; ~60 s dark to become a bar again
    static constexpr float kMinPicture = 0.35f;
    static constexpr int kMinBar = 2;

    /** rgb: float CHW in [0, 1], w x h; filled in place. Returns the picture {x, y, width, height}. */
    std::array<int, 4> apply(float* rgb, int w, int h) {
        if (w != w_ || h != h_) { w_ = w; h_ = h; rows_.assign(h, 0); cols_.assign(w, 0); seen_ = 0; }
        const size_t n = static_cast<size_t>(w) * h;
        std::vector<float> row(h, 0.f), col(w, 0.f);
        for (int y = 0; y < h; ++y) for (int x = 0; x < w; ++x) {
            const size_t p = static_cast<size_t>(y) * w + x;
            const float luma = 0.299f * rgb[p] + 0.587f * rgb[n + p] + 0.114f * rgb[2 * n + p];
            row[y] = std::max(row[y], luma); col[x] = std::max(col[x], luma);
        }
        for (int y = 0; y < h; ++y) rows_[y] = row[y] < kBlack ? rows_[y] + 1 : 0;
        for (int x = 0; x < w; ++x) cols_[x] = col[x] < kBlack ? cols_[x] + 1 : 0;
        ++seen_;
        int top = 0, left = 0, bottom = 0, right = 0;
        if (seen_ >= kWarm) { bottom = edges(rows_, &top); right = edges(cols_, &left); }
        if (!bars(top, bottom, h)) { top = 0; bottom = h; }
        if (!bars(left, right, w)) { left = 0; right = w; }
        rect_ = {left, top, right - left, bottom - top};
        if (top > 0 || bottom < h || left > 0 || right < w) fill(rgb, w, h);
        return rect_;
    }
    const std::array<int, 4>& picture() const { return rect_; }
    void reset() { w_ = h_ = 0; }

private:
    int w_ = 0, h_ = 0;
    std::vector<long> rows_, cols_; // consecutive dark frames per line
    long seen_ = 0;
    std::array<int, 4> rect_{{0, 0, 0, 0}};

    /** First and one-past-last lit line; the outermost lit line is a bar/picture blend, so one more
     * line goes to each bar. */
    int edges(const std::vector<long>& dark, int* first) const {
        const int n = static_cast<int>(dark.size());
        const long bar = std::min<long>(seen_, kSettle);
        int a = 0, b = n;
        while (a < n && dark[a] >= bar) ++a;
        while (b > a && dark[b - 1] >= bar) --b;
        if (a == n) { *first = 0; return 0; } // all dark: no picture to keep
        if (a > 0) ++a;
        if (b < n) --b;
        *first = a;
        return std::max(a, b);
    }
    static bool bars(int a, int b, int n) {
        const int lo = a, hi = n - b, big = std::max(lo, hi);
        return lo >= kMinBar && hi >= kMinBar && b - a >= kMinPicture * n &&
               std::abs(lo - hi) <= 2 + big / 5;
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
