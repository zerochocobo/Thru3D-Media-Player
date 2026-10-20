#pragma once
#include <functional>
#include <string>
#include <vector>
#include <cstdint>
namespace thru {
struct HdrInfo { int width, height, format; }; // 1 Radiance, 2 OpenEXR
HdrInfo hdr_info(const std::string &path);
std::vector<uint8_t> hdr_pixels(const std::string &path, int left, int top, int width, int height,
    int sample, const std::function<void()> &check, const std::string &cache);
}
