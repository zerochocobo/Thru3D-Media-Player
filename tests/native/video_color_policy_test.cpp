#include "../../native/mpv/video_output_policy.h"
#include <iostream>
#include <stdexcept>

int main() {
    int checks = 0;
    auto check = [&](bool ok, const char* why) {
        ++checks;
        if (!ok) throw std::runtime_error(why);
    };
    using quest::needs_sdr_color_conversion;
    using quest::can_export_decoder_image;
    // The user's ten DV 8.1 files have a PQ/BT.2020 HDR10-compatible base.
    // They need conversion even though the Profile 5 flag is false.
    for (auto transfer : {"pq", "smpte2084", "hlg", "arib-std-b67"}) {
        check(needs_sdr_color_conversion(transfer, false), "HDR/DV8 base must be converted to SDR");
        check(!can_export_decoder_image(true, false, 0, true,
              needs_sdr_color_conversion(transfer, false)), "HDR cannot bypass MPV color conversion");
    }
    // Unknown/untagged SDR and existing limited/full-range SDR all retain the
    // same direct-export decision. Mask packing/eye layout do not choose color policy.
    for (auto transfer : {"", "auto", "unknown", "bt.1886", "srgb", "gamma2.2", "gamma2.4", "bt709", "linear"}) {
        check(!needs_sdr_color_conversion(transfer, false), "SDR must retain its existing color path");
        for (bool request : {false, true}) for (bool redraw : {false, true})
            for (bool hardware : {false, true}) for (int rotation : {0, 90, 180, 270}) {
                const bool before = request && !redraw && rotation == 0 && hardware;
                check(can_export_decoder_image(request, redraw, rotation, hardware,
                      needs_sdr_color_conversion(transfer, false)) == before,
                      "SDR output changed for an existing decoder/redraw/rotation path");
            }
        check(needs_sdr_color_conversion(transfer, true), "Profile 5 conversion must survive missing/wrong tags");
    }
    for (bool request : {false, true}) for (bool redraw : {false, true})
        for (bool hardware : {false, true}) for (int rotation : {0, 90, 180, 270}) {
            check(!can_export_decoder_image(request, redraw, rotation, hardware, true),
                  "Conversion must not export an unconverted image");
        }
    std::cout << "Video color policy checks=" << checks << " failures=0\n";
}
