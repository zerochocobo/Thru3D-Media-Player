#include "../../native/xr-layer/layer_layout.h"
#include <iostream>

int main() {
    int checks = 0, failures = 0;
    const auto check = [&](bool ok, const char* label) {
        ++checks;
        if (!ok) { ++failures; std::cerr << label << '\n'; }
    };
    XrCompositionLayerSettingsFB tail{};
    tail.type = XR_TYPE_COMPOSITION_LAYER_SETTINGS_FB;
    XrCompositionLayerImageLayoutFB layout{};
    auto next = quest::image_layout_next(layout, 0.0f, &tail);
    check(next == &layout, "No-flip mode must submit an explicit layout struct");
    check(layout.type == XR_TYPE_COMPOSITION_LAYER_IMAGE_LAYOUT_FB, "Layout struct type");
    check(layout.flags == 0, "PICO no-flip submission uses zero flags");
    check(layout.next == &tail, "Existing extension chain is preserved");
    next = quest::image_layout_next(layout, 1.0f, nullptr);
    check(next == &layout && layout.flags == XR_COMPOSITION_LAYER_IMAGE_LAYOUT_VERTICAL_FLIP_BIT_FB,
          "Quest Surface and GL picture submission retains the flip bit");
    check(layout.next == nullptr, "No previous tail survives a new submission");
    next = quest::image_layout_next(layout, 0.0f, nullptr);
    check(next == &layout && layout.flags == 0, "Switching flip to no-flip clears the previous flags");
    next = quest::image_layout_next(layout, -1.0f, &tail);
    check(next == &tail, "Unsupported extension is omitted without removing other extensions");
    check(quest::image_layout_next(layout, -1.0f, nullptr) == nullptr, "Unsupported extension has no struct");
    const float full[] = {0, 0, 4096, 4096};
    const float negative[] = {-20, 0, 2048, 4096};
    const float overflow[] = {2049, 0, 2048, 4096};
    const float vertical[] = {0, 1, 2048, 4096};
    const float zero[] = {0, 0, 0.1f, 4096};
    const float huge[] = {0, 0, 1e30f, 4096};
    const float nan[] = {NAN, 0, 2048, 4096};
    check(quest::image_rect_valid(full, 4096, 4096), "Full swapchain rectangle is valid");
    for (const auto* invalid : {negative, overflow, vertical, zero, huge, nan})
        check(!quest::image_rect_valid(invalid, 4096, 4096), "Unsafe rectangle cannot reach xrEndFrame");
    check(!quest::image_rect_valid(full, 3840, 1080), "Validate actual picture dimensions, not nominal Surface dimensions");
    std::cout << "Layer layout: " << checks << " checks, " << failures << " failures\n";
    return failures ? 1 : 0;
}
