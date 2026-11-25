// Host test of the 2D->3D foreground scale (native/rvm/near_foreground.h).
// Build (Windows): tools/Test-DepthStabilizer.ps1 -Foreground
#include "../../native/rvm/near_foreground.h"

#include <cstdio>

static int failures = 0, checks = 0;
static void check(bool ok, const char* what) {
    ++checks;
    if (!ok) { ++failures; std::printf("FAIL: %s\n", what); }
}

int main() {
    using quest::near_foreground;
    for (const float plane : {.05f, .35f, .65f}) {
        for (const float scale : {-1.f, -.5f, .5f, 1.f}) {
            const float p = quest::near_foreground_exponent(scale);
            check(std::fabs(near_foreground(plane, p, plane) - plane) < 1e-5f, "the screen plane stays put");
            bool rising = true, bounded = true;
            float last = -1.f;
            for (int i = 0; i <= 255; ++i) {
                const float v = near_foreground(i / 255.f, p, plane);
                rising &= v >= last; bounded &= v >= 0.f && v <= 1.f; last = v;
            }
            check(rising, "the curve keeps the depth order");
            check(bounded, "the curve stays within the map");
        }
    }
    const float plane = .35f;
    // Positive: more layers at the near end than at the far end; negative: the other way round.
    const auto slope = [&](float scale, float at) {
        const float p = quest::near_foreground_exponent(scale);
        return (near_foreground(at + .01f, p, plane) - near_foreground(at - .01f, p, plane)) / .02f;
    };
    check(slope(1.f, .9f) > 1.2f && slope(1.f, .1f) < .5f, "positive spreads the foreground and flattens the background");
    check(slope(-1.f, .1f) > 2.f * slope(-1.f, .9f), "negative spreads the background and flattens the foreground");
    const auto table = quest::near_foreground_table(1.f, plane);
    bool identity = true;
    for (int i = 0; i < 256; ++i) identity &= std::fabs(table[i] - i / 255.f) < 1e-6f;
    check(identity, "zero leaves the model's map");
    check(near_foreground(.7f, quest::near_foreground_exponent(0.f), plane) == .7f, "exponent 1 is the identity");
    std::printf("%d/%d checks passed\n", checks - failures, checks);
    return failures == 0 ? 0 : 1;
}
