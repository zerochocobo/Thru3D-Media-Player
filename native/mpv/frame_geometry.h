#pragma once
#include <algorithm>
#include <cmath>
#include <stdexcept>
#include <string>

namespace quest {
inline int frame_rotation(int degrees) {
    const int rotation = (degrees % 360 + 360) % 360;
    if (rotation % 90 != 0) throw std::runtime_error("MPV source rotation must use 90-degree steps");
    return rotation;
}
inline bool quarter_turn(int rotation) { return rotation == 90 || rotation == 270; }
struct ColorSize { int width, height; };
// libmpv's GPU renderer applies the source rotation. Its target must have the
// displayed dimensions, rather than stretching the rotated image into the raw size.
inline ColorSize frame_color_size(int width, int height, int rotation, int width_cap) {
    if (quarter_turn(rotation)) std::swap(width, height);
    if (width_cap > 0 && width > width_cap) {
        const int scaled_width = width_cap & ~1;
        height = std::max(2, static_cast<int>(std::lround(static_cast<double>(height) * scaled_width / width)) & ~1);
        width = scaled_width;
    }
    return {width, height};
}
inline double frame_pixel_aspect(double par, int rotation) {
    return quarter_turn(rotation) ? 1.0 / par : par;
}
// Rotation applies to the packed canvas too. Describe the resulting packing and
// eye order so automatic layout detection splits the normalized image correctly.
inline std::string frame_stereo_mode(const std::string& mode, int rotation) {
    const bool sbs = mode == "sbsl" || mode == "sbsr" || mode == "sbs2l" || mode == "sbs2r" ||
        mode == "side_by_side" || mode == "right_left";
    const bool tb = mode == "abl" || mode == "abr" || mode == "ab2l" || mode == "ab2r" ||
        mode == "top_bottom" || mode == "bottom_top";
    if (rotation == 0 || (!sbs && !tb)) return mode;
    const bool reverse = mode == "sbsr" || mode == "sbs2r" || mode == "abr" || mode == "ab2r" ||
        mode == "right_left" || mode == "bottom_top";
    const bool flip = rotation == 180 || (sbs ? rotation == 270 : rotation == 90);
    const bool half = mode == "sbs2l" || mode == "sbs2r" || mode == "ab2l" || mode == "ab2r";
    return std::string(sbs != quarter_turn(rotation) ? "sbs" : "ab") +
        (half ? "2" : "") + (reverse != flip ? "r" : "l");
}
} // namespace quest
