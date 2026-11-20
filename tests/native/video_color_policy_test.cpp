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
    // A layer file MediaCodec refuses: the software decoder is named in MPV's log, and a file with
    // nothing else to play ends as nothing to play; that end moves it off the layer.
    using quest::layer_software_decoder;
    using quest::layer_end_is_software_fallback;
    check(layer_software_decoder(true, false, "vd", "Using software decoding."), "The layer notes MPV's software decoder");
    check(!layer_software_decoder(true, true, "vd", "Using software decoding."), "A software layer session expects it");
    check(!layer_software_decoder(false, false, "vd", "Using software decoding."), "The eye buffers take software frames");
    check(!layer_software_decoder(true, false, "cplayer", "Using software decoding."), "Only the decoder's own line counts");
    check(layer_end_is_software_fallback(true, false, true, true), "A silent software file on the layer falls back");
    check(!layer_end_is_software_fallback(true, false, false, true), "Nothing to play with a hardware decoder stays a failure");
    check(!layer_end_is_software_fallback(true, false, true, false), "Other errors stay failures");
    check(!layer_end_is_software_fallback(false, false, true, true), "The eye buffers have nowhere to fall back to");
    std::cout << "Video color policy checks=" << checks << " failures=0\n";
}
