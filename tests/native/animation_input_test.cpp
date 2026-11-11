#include "../../native/image/animation_input.h"
#include <iostream>
#include <vector>

static void check(bool value) {
    if (!value) throw std::runtime_error("Animation input check failed");
}

int main() {
    using thru::image::animation_input;
    const uint8_t pixels[] = {255,0,0,255, 0,255,0,255};
    float rgb[4*4*3]{};
    const auto rect = animation_input(pixels, sizeof(pixels), 2, 1, rgb, 48, 4, 4);
    check((rect == std::array<int,4>{0,1,4,2}));
    for (int y = 0; y < 4; ++y) {
        check(rgb[y*4] == 1.f && rgb[y*4+3] == 0.f);
        check(rgb[16+y*4] == 0.f && rgb[16+y*4+3] == 1.f);
        check(rgb[y*4+1] == 0.75f && rgb[y*4+2] == 0.25f);
        check(rgb[32+y*4+2] == 0.f);
    }
    const uint8_t transparent[] = {255,0,0,0};
    animation_input(transparent,4,1,1,rgb,48,4,4);
    for (float value : rgb) check(value == 0.5f);
    const uint8_t portrait[] = {0,0,255,255, 0,0,255,255};
    check((animation_input(portrait,8,1,2,rgb,48,4,4) == std::array<int,4>{1,0,2,4}));
    for (int i = 0; i < 32; ++i) check(rgb[i] == 0.f);
    for (int i = 32; i < 48; ++i) check(rgb[i] == 1.f);
    int rejected = 0;
    auto bad = [&](const uint8_t* data, size_t bytes, int sw, int sh, size_t floats, int w, int h) {
        try { animation_input(data,bytes,sw,sh,rgb,floats,w,h); }
        catch(const std::invalid_argument&) { rejected++; }
    };
    bad(nullptr,8,2,1,48,4,4); bad(pixels,7,2,1,48,4,4);
    bad(pixels,8,0,1,48,4,4); bad(pixels,8,2,1,47,4,4);
    bad(pixels,8,2,1,48,1025,4); bad(pixels,8,2049,1,48,4,4);
    check(rejected == 6);
    std::cout << "Animation model input: RGB/alpha, aspect/edge padding and 6 invalid bounds passed\n";
}
