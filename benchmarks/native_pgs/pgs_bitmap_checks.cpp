#include "../../native/mpv/pgs_bitmap.h"
#include <iostream>
#include <string>
#include <chrono>

int main() {
    int checks = 0;
    auto check = [&](bool ok) { if (!ok) throw std::runtime_error("PGS pixel check " + std::to_string(checks)); ++checks; };
    const uint8_t padded[] = {0,0,128,128, 255,0,0,255, 9,9,9,9,
                              0,128,0,128, 0,0,0,0, 9,9,9,9};
    quest_mpv_pgs_part part{padded,12,2,2, 3,5,2,2};
    quest_mpv_pgs_frame frame{10,10,9,1,1,&part};
    auto image = quest::compose_pgs(frame);
    check(image.x == 3 && image.y == 5 && image.width == 2 && image.height == 2);
    check(image.rgba == std::vector<uint8_t>({128,0,0,128, 0,0,255,255, 0,128,0,128, 0,0,0,0}));
    part.x = -1; part.y = -1;
    image = quest::compose_pgs(frame);
    check(image.width == 1 && image.height == 1 && image.rgba == std::vector<uint8_t>({0,0,0,0}));
    const uint8_t red[] = {0,0,128,128};
    const uint8_t blue[] = {128,0,0,128};
    quest_mpv_pgs_part overlap[] = {{blue,4,1,1,0,0,1,1}, {red,4,1,1,0,0,1,1}};
    frame = {2,2,1,1,2,overlap};
    image = quest::compose_pgs(frame);
    check(image.rgba == std::vector<uint8_t>({128,0,64,192}));
    part = {padded,12,2,2,0,0,1,1}; frame = {2,2,1,1,1,&part};
    image = quest::compose_pgs(frame);
    check(image.rgba == std::vector<uint8_t>({32,32,64,128}));
    frame.num_parts = 0;
    check(quest::compose_pgs(frame).rgba.empty());
    frame.num_parts = 1; part.x = 10; part.y = 10;
    check(quest::compose_pgs(frame).rgba.empty());
    part.x = 0; part.y = 0; part.stride = 1;
    bool rejected = false;
    try { quest::compose_pgs(frame); } catch (const std::exception&) { rejected = true; }
    check(rejected);
    const std::vector<uint8_t> original = {
        255,255,255,255, 0,0,0,255, 128,128,128,255, 128,128,128,128,
        0,0,0,0, 255,0,0,255, 0,128,0,128, 250,248,246,255};
    for (const uint32_t tint : {0xffe066u, 0x80eaffu, 0xa7f08bu, 0xffa8ccu}) {
        auto pixels = original;
        quest::tint_pgs_rgba(pixels, tint);
        check(pixels[0] == ((tint >> 16) & 255) && pixels[1] == ((tint >> 8) & 255) && pixels[2] == (tint & 255));
        check(pixels[4] == 0 && pixels[5] == 0 && pixels[6] == 0); // Black outline.
        check(std::equal(pixels.begin()+20, pixels.begin()+28, original.begin()+20)); // Authored colors.
        for (size_t i = 3; i < pixels.size(); i += 4) check(pixels[i] == original[i]);
        for (size_t i = 0; i < pixels.size(); i += 4)
            check(pixels[i] <= pixels[i+3] && pixels[i+1] <= pixels[i+3] && pixels[i+2] <= pixels[i+3]);
        for (int c = 0; c < 3; ++c) {
            check(std::abs(pixels[8+c] * 2 - pixels[c]) <= 1); // Gray antialiasing.
            check(pixels[8+c] == pixels[12+c]); // Translucent white, with no second alpha multiplication.
        }
        check(pixels[28] != original[28] || pixels[29] != original[29] || pixels[30] != original[30]);
    }
    auto restored = original;
    quest::tint_pgs_rgba(restored, 0xffffff);
    check(restored == original); // Original is bit-exact, including colored glyphs.
    // Chroma thresholds are relative to alpha, and feather instead of a hard replacement.
    std::vector<uint8_t> gate = {255,235,235,255, 255,222,222,255, 255,209,209,255};
    quest::tint_pgs_rgba(gate, 0x80eaff);
    check(gate[0] < gate[4] && gate[4] < gate[8] && gate[8] == 255);
    std::vector<uint8_t> crop(1280 * 160 * 4, 255);
    const auto start = std::chrono::steady_clock::now();
    for (int n = 0; n < 100; ++n) {
        auto colored = crop;
        quest::tint_pgs_rgba(colored, 0xffe066);
        check(colored[2] == 102);
    }
    const double ms = std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count()/100;
    std::cout << "PGS tint 1280x160 crop including copy: " << ms << " ms/cue (host)\n";
    std::cout << "PGS crop/palette/alpha/stride/scale/clipping/tint checks passed: " << checks << '\n';
}
