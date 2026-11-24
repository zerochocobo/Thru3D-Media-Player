// Host test of the 2D->3D flat frame edges (native/rvm/near_edge_fade.h).
// Build (Windows): tools/Test-DepthStabilizer.ps1 -Fade
#include "../../native/rvm/near_edge_fade.h"

#include <cstdio>
#include <vector>

static int failures = 0, checks = 0;
static void check(bool ok, const char* what) {
    ++checks;
    if (!ok) { ++failures; std::printf("FAIL: %s\n", what); }
}

int main() {
    const int w = 512, h = 8, cx = 0, cy = 2, cw = 512, ch = 4;
    const float plane = .35f, shift = .00875f; // default strength
    const float slope = 2.f * quest::kNearEdgeStretch / (shift * cw);
    auto faded = [&](float value, float strength_shift) {
        std::vector<float> near(static_cast<size_t>(w) * h, value);
        quest::near_edge_fade(near.data(), w, cx, cy, cw, ch, strength_shift, plane);
        return near;
    };
    const auto near = faded(1.f, shift);
    const float* row = near.data() + static_cast<size_t>(cy) * w;
    check(std::fabs(row[0] - plane) < .03f && std::fabs(row[w - 1] - plane) < .03f, "both edges reach the screen plane");
    bool rising = true, bounded = true;
    for (int x = 1; x < cw / 2; ++x) {
        rising &= row[x] >= row[x - 1] && row[w - 1 - x] >= row[w - x];
        bounded &= row[x] - row[x - 1] <= slope * 1.001f && std::fabs(row[x] - plane) <= slope * (x + .5f);
    }
    check(rising, "the map eases monotonically from each edge");
    check(bounded, "the map stays inside the cone and never steeper than its slope (the stretch bound)");
    check(row[w / 2] > .99f, "the middle of the picture keeps its depth");
    int reach = 0;
    while (reach < cw / 2 && row[reach] < .65f + plane - .065f) ++reach; // within 10% of the full offset
    check(reach > 8 && reach < 26, "nearest content is back within 10% some 2-5% of the width from the edge");
    check(near[0] == 1.f && near[static_cast<size_t>(cy + ch) * w] == 1.f, "rows outside the picture are untouched");
    {
        const auto on_plane = faded(plane, shift);
        bool same = true;
        for (float v : on_plane) same &= v == plane;
        check(same, "content on the plane is not touched");
        const auto slight = faded(plane + .05f, shift);
        const float* r = slight.data() + static_cast<size_t>(cy) * w;
        int n = 0;
        while (n < cw / 2 && r[n] < plane + .045f) ++n;
        check(n <= 3, "content slightly off the plane is reached for a few texels only");
    }
    {
        const auto far = faded(0.f, shift);
        check(std::fabs(far[static_cast<size_t>(cy) * w] - plane) < .03f, "content behind the plane comes forward to it at the edge");
    }
    {
        const auto strong = faded(1.f, .035f); // 200%
        const float* r = strong.data() + static_cast<size_t>(cy) * w;
        int n = 0;
        while (n < cw / 2 && r[n] < .65f + plane - .065f) ++n;
        check(n > reach * 3, "a stronger effect reaches further in, at the same stretch");
    }
    {
        std::vector<float> narrow(static_cast<size_t>(w) * h, 1.f);
        quest::near_edge_fade(narrow.data(), w, 200, cy, 3, ch, shift, plane); // a 3-texel picture
        check(narrow[static_cast<size_t>(cy) * w + 199] == 1.f && narrow[static_cast<size_t>(cy) * w + 203] == 1.f, "a narrow picture stays inside its columns");
    }
    std::printf("near edge fade checks=%d failures=%d\n", checks, failures);
    return failures ? 1 : 0;
}
