#pragma once
#include <cstdint>
#include <functional>
#include <string>
#include <vector>

namespace thru {
struct TiffInfo { int width, height, orientation; bool scanlines; };
TiffInfo tiff_info(const std::string &path);
// Cropping is in stored-image coordinates; the existing photo path applies EXIF orientation.
std::vector<uint8_t> tiff_pixels(const std::string &path, int left, int top, int width,
                                int height, int sample, const std::function<void()> &checkpoint,
                                const std::string &cache = {});
}
