#pragma once
#include <openxr/openxr.h>
#include <cmath>

namespace quest {
// Top-left browser coordinates become bottom-up swapchain coordinates on flipped runtimes.
inline XrRect2Di browser_image_rect(const float* p, int height, bool flipped) {
    const auto x = static_cast<int32_t>(std::lround(p[0])), y = static_cast<int32_t>(std::lround(p[1]));
    const auto w = static_cast<int32_t>(std::lround(p[2])), h = static_cast<int32_t>(std::lround(p[3]));
    return {{x, flipped ? height - y - h : y}, {w, h}};
}
// Validate before converting floats or exposing any layer to xrEndFrame. A bad subimage
// rejects the entire frame, including menus, and can recur from per-file saved alignment.
inline bool image_rect_valid(const float* p, int width, int height) {
    for (int i = 0; i < 4; ++i) if (!std::isfinite(p[i])) return false;
    if (width <= 0 || height <= 0 || p[0] < 0 || p[1] < 0 || p[2] <= 0 || p[3] <= 0 ||
        p[0] > width || p[1] > height || p[2] > width || p[3] > height) return false;
    const auto x = std::lround(p[0]), y = std::lround(p[1]);
    const auto w = std::lround(p[2]), h = std::lround(p[3]);
    return w > 0 && h > 0 && x + w <= width && y + h <= height;
}
// Godot/native ABI field 17: -1 = extension unavailable, 0 = explicit no flip, 1 = flip.
// Keep the caller-owned struct in the chain even with flags=0, matching Godot Vendors.
inline const void* image_layout_next(XrCompositionLayerImageLayoutFB& layout, float mode, void* next) {
    if (mode < 0.0f) return next;
    layout = {};
    layout.type = XR_TYPE_COMPOSITION_LAYER_IMAGE_LAYOUT_FB;
    layout.next = next;
    layout.flags = mode > 0.5f ? XR_COMPOSITION_LAYER_IMAGE_LAYOUT_VERTICAL_FLIP_BIT_FB : 0;
    return &layout;
}
}
