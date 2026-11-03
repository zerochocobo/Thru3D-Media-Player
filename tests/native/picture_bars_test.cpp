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

// Feeds the same frame for the warm-up (a copy each time: apply fills in place).
static std::array<int, 4> warm(PictureBars& bars, const std::vector<float>& rgb, int w, int h, std::vector<float>* last = nullptr) {
    std::array<int, 4> r{};
    for (int i = 0; i < PictureBars::kWarm; ++i) { auto copy = rgb; r = bars.apply(copy.data(), w, h); if (last) *last = copy; }
    return r;
}

int main() {
    const int w = 384, h = 224;
    {
        PictureBars bars;
        auto rgb = frame(w, h, 28, 28, 0, 0, .5f);
        auto first = rgb;
        const auto early = bars.apply(first.data(), w, h);
        check(early[1] == 0 && early[3] == h, "nothing is cropped before the warm-up");
        const auto r = warm(bars, frame(w, h, 28, 28, 0, 0, .5f), w, h, &rgb);
        check(r[1] == 29 && r[3] == h - 58 && r[0] == 0 && r[2] == w, "2.39:1 bars leave the picture rows, one blend row inside");
        bool filled = true;
        for (int x = 0; x < w; ++x) filled &= rgb[x] == rgb[29 * w + x] && rgb[(h - 1) * w + x] == rgb[(h - 30) * w + x];
        check(filled, "bars repeat the picture's edge lines");
    }
    {
        PictureBars bars;
        const auto r = warm(bars, frame(w, h, 0, 0, 48, 48, .5f), w, h);
        check(r[0] == 49 && r[2] == w - 98 && r[1] == 0 && r[3] == h, "pillarbox bars");
    }
    {
        PictureBars bars;
        auto lit = frame(w, h, 28, 28, 0, 0, .5f), dark = frame(w, h, 60, 60, 0, 0, .5f);
        warm(bars, lit, w, h);
        std::array<int, 4> r{};
        for (int i = 0; i < 900; ++i) { auto d = dark; r = bars.apply(d.data(), w, h); }
        check(r[1] == 29, "a darker scene inside the same bars does not move the edge for 30 s");
        PictureBars sides;
        warm(sides, frame(w, h, 28, 28, 0, 0, .5f), w, h);
        for (int i = 0; i < 900; ++i) { auto d = frame(w, h, 28, 28, 60, 60, .5f); r = sides.apply(d.data(), w, h); }
        check(r[0] == 0 && r[2] == w, "a scene with black sides after lit sides is not a pillarbox");
    }
    {
        PictureBars bars;
        const auto r = warm(bars, frame(w, h, 40, 0, 0, 0, .5f), w, h); // a dark sky on top only: not symmetric bars
        check(r[1] == 0 && r[3] == h, "one-sided dark band is picture");
    }
    {
        PictureBars bars;
        auto r = warm(bars, frame(w, h, 0, 0, 0, 0, 0.f), w, h);
        check(r[1] == 0 && r[3] == h, "an all-black frame crops nothing");
        PictureBars logo;
        r = warm(logo, frame(w, h, 90, 90, 0, 0, .5f), w, h);
        check(r[1] == 0 && r[3] == h, "a picture under kMinPicture of the input is not taken for bars");
    }
    {
        PictureBars bars;
        const auto copy = frame(w, h, 0, 0, 0, 0, .5f);
        std::vector<float> full;
        const auto r = warm(bars, copy, w, h, &full);
        check(r[0] == 0 && r[1] == 0 && r[2] == w && r[3] == h && full == copy, "full-frame video is left untouched");
    }
    std::printf("picture bars checks=%d failures=%d\n", checks, failures);
    return failures ? 1 : 0;
}
