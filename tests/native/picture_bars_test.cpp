// Host test of burned-in letterbox detection for the video depth model input (native/rvm/picture_bars.h).
// Build (Windows): tools/Test-DepthStabilizer.ps1 -Bars
#include "../../native/rvm/picture_bars.h"

#include <cstdio>
#include <vector>

using quest::PictureBars;
static int failures = 0, checks = 0;
static void check(bool ok, const char* what) {
    ++checks;
    if (!ok) { ++failures; std::printf("FAIL: %s\n", what); }
}

// CHW frame: picture rows [top, h - bottom) and columns [left, w - right) at `level`, black elsewhere.
static std::vector<float> frame(int w, int h, int top, int bottom, int left, int right, float level) {
    std::vector<float> rgb(static_cast<size_t>(w) * h * 3, 0.f);
    for (int c = 0; c < 3; ++c) for (int y = top; y < h - bottom; ++y) for (int x = left; x < w - right; ++x)
        rgb[c * w * h + y * w + x] = level * (0.6f + 0.4f * ((x + y + c) % 7) / 6.f);
    return rgb;
}

// One frame (a copy: apply fills in place).
static std::array<int, 4> once(PictureBars& bars, const std::vector<float>& rgb, int w, int h, std::vector<float>* out = nullptr) {
    auto copy = rgb;
    const auto r = bars.apply(copy.data(), w, h);
    if (out) *out = copy;
    return r;
}
// The same frame until new bars apply (kHold frames).
static std::array<int, 4> feed(PictureBars& bars, const std::vector<float>& rgb, int w, int h, std::vector<float>* out = nullptr) {
    std::array<int, 4> r{};
    for (int i = 0; i < PictureBars::kHold; ++i) r = once(bars, rgb, w, h, out);
    return r;
}

int main() {
    const int w = 384, h = 224;
    {
        PictureBars bars;
        std::vector<float> rgb;
        auto r = once(bars, frame(w, h, 28, 28, 0, 0, .5f), w, h);
        check(r[1] == 0 && r[3] == h, "bars wait kHold frames");
        for (int i = 2; i <= PictureBars::kHold; ++i) r = once(bars, frame(w, h, 28, 28, 0, 0, .5f), w, h, &rgb);
        check(r[1] == 29 && r[3] == h - 58 && r[0] == 0 && r[2] == w, "2.39:1 bars after kHold frames, one blend row inside");
        bool filled = true;
        for (int x = 0; x < w; ++x) filled &= rgb[x] == rgb[29 * w + x] && rgb[(h - 1) * w + x] == rgb[(h - 30) * w + x];
        check(filled, "bars repeat the picture's edge lines");
    }
    {
        PictureBars bars;
        const auto r = feed(bars, frame(w, h, 0, 0, 48, 48, .5f), w, h);
        check(r[0] == 49 && r[2] == w - 98 && r[1] == 0 && r[3] == h, "pillarbox bars (a portrait page in fullscreen)");
    }
    {
        PictureBars bars;
        feed(bars, frame(w, h, 28, 28, 0, 0, .5f), w, h);
        auto r = once(bars, frame(w, h, 60, 60, 0, 0, .5f), w, h);
        check(r[1] == 29 && r[3] == h - 58, "a darker scene inside the bars does not widen them");
        r = once(bars, frame(w, h, 0, 0, 0, 0, 0.f), w, h);
        check(r[1] == 29 && r[3] == h - 58, "an all-black frame (a fade) keeps the bars");
        PictureBars dark_start;
        feed(dark_start, frame(w, h, 60, 60, 0, 0, .5f), w, h);
        r = once(dark_start, frame(w, h, 28, 28, 0, 0, .5f), w, h);
        check(r[1] == 29 && r[3] == h - 58, "bars found in a dark first scene narrow as soon as their lines light");
        r = once(bars, frame(w, h, 60, 28, 0, 0, .5f), w, h);
        check(r[1] == 29 && r[3] == h - 58, "a dark picture edge beside one bar stays picture: both bars keep the narrower size");
        r = once(bars, frame(w, h, 0, 0, 0, 0, .5f), w, h);
        check(r[1] == 0 && r[3] == h, "the bars stop on the first frame their lines light");
        PictureBars flicker;
        bool never = true;
        for (int i = 0; i < 40; ++i) {
            const int dark = i % 4 == 3 ? 0 : 30;
            r = once(flicker, frame(w, h, 0, 0, dark, dark, .5f), w, h);
            never &= r[0] == 0 && r[2] == w;
        }
        check(never, "dark sides that light every few frames never become bars");
    }
    {
        PictureBars bars;
        auto rgb = frame(w, h, 28, 28, 0, 0, .5f);
        rgb[5 * w + 100] = .1f; // one lit pixel in the top bar (luma over kBlack)
        const auto r = feed(bars, rgb, w, h);
        check(r[1] == 6 && r[3] == h - 12, "a lit line is picture: both bars stop short of it");
    }
    {
        PictureBars bars;
        const auto r = feed(bars, frame(w, h, 40, 0, 0, 0, .5f), w, h); // a dark sky on top only: not symmetric bars
        check(r[1] == 0 && r[3] == h, "one-sided dark band is picture");
    }
    {
        PictureBars bars;
        auto r = feed(bars, frame(w, h, 0, 0, 0, 0, 0.f), w, h);
        check(r[1] == 0 && r[3] == h && r[0] == 0 && r[2] == w, "an all-black frame crops nothing");
        PictureBars logo;
        r = feed(logo, frame(w, h, 90, 90, 0, 0, .5f), w, h);
        check(r[1] == 0 && r[3] == h, "a picture under kMinPicture of the input is not taken for bars");
    }
    {
        PictureBars bars;
        const auto copy = frame(w, h, 0, 0, 0, 0, .5f);
        std::vector<float> full;
        const auto r = feed(bars, copy, w, h, &full);
        check(r[0] == 0 && r[1] == 0 && r[2] == w && r[3] == h && full == copy, "full-frame video is left untouched");
    }
    std::printf("picture bars checks=%d failures=%d\n", checks, failures);
    return failures ? 1 : 0;
}
