#include "pgs_bitmap.h"

namespace quest {
void tint_pgs_rgba(std::vector<uint8_t>& rgba, uint32_t rgb) {
    if (rgb == 0xffffff) return;
    const int tint[] = {static_cast<int>((rgb >> 16) & 255),
                        static_cast<int>((rgb >> 8) & 255), static_cast<int>(rgb & 255)};
    uint8_t channels[3][256];
    for (int c = 0; c < 3; ++c) for (int v = 0; v < 256; ++v)
        channels[c][v] = static_cast<uint8_t>((v * tint[c] + 127) / 255);
    for (size_t i = 0; i + 3 < rgba.size(); i += 4) {
        auto* pixel = rgba.data() + i;
        const int alpha = pixel[3];
        if (!alpha || !(pixel[0] | pixel[1] | pixel[2])) continue;
        const int chroma = std::max({pixel[0], pixel[1], pixel[2]}) -
                           std::min({pixel[0], pixel[1], pixel[2]});
        if (100 * chroma <= 8 * alpha) {
            for (int c = 0; c < 3; ++c) pixel[c] = channels[c][pixel[c]];
            continue;
        }
        if (100 * chroma >= 18 * alpha) continue;
        // Relative to alpha: translucent white gets the same hue, with no second
        // alpha multiplication. Feather near-neutral ink instead of a hard key.
        const int weight = (18 * alpha - 100 * chroma) * 255 / (10 * alpha);
        for (int c = 0; c < 3; ++c) {
            const int original = pixel[c];
            const int colored = channels[c][original];
            pixel[c] = static_cast<uint8_t>((original * (255-weight) + colored * weight + 127) / 255);
        }
    }
}
}
