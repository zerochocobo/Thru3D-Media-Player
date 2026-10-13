#include "../../native/mpv/frame_geometry.h"
#include <iostream>

int main() {
    auto check = [](bool ok) { if (!ok) throw std::runtime_error("Frame geometry expectation failed"); };
    check(quest::frame_rotation(-90) == 270 && quest::frame_rotation(360) == 0);
    const auto portrait = quest::frame_color_size(3840, 2160, 90, 0);
    check(portrait.width == 2160 && portrait.height == 3840);
    const auto capped = quest::frame_color_size(3840, 2160, 270, 1920);
    check(capped.width == 1920 && capped.height == 3412);
    const auto upside_down = quest::frame_color_size(3840, 2160, 180, 0);
    check(upside_down.width == 3840 && upside_down.height == 2160);
    check(quest::frame_pixel_aspect(2.0, 90) == 0.5 && quest::frame_pixel_aspect(2.0, 180) == 2.0);
    check(quest::frame_stereo_mode("sbsl", 90) == "abl");
    check(quest::frame_stereo_mode("sbs2l", 270) == "ab2r");
    check(quest::frame_stereo_mode("abl", 90) == "sbsr");
    check(quest::frame_stereo_mode("abr", 270) == "sbsr");
    check(quest::frame_stereo_mode("sbsr", 180) == "sbsl");
    check(quest::frame_stereo_mode("mono", 90) == "mono");
    bool rejected = false;
    try { quest::frame_rotation(45); } catch (const std::runtime_error&) { rejected = true; }
    check(rejected);
    std::cout << "MPV frame geometry checks passed\n";
}
