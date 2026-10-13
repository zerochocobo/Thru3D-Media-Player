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
    std::cout << "Layer layout: " << checks << " checks, " << failures << " failures\n";
    return failures ? 1 : 0;
}
