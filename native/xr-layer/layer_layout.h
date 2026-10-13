#pragma once
#include <openxr/openxr.h>

namespace quest {
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
