#pragma once
#include <string_view>

namespace quest {
// Decoder OES sampling converts YUV to RGB, but cannot tone-map PQ/HLG or map
// their wide gamut into the SDR eye-buffer contract. Profile 5 additionally
// needs the existing RPU/IPT conversion, even without a container transfer tag.
inline bool needs_sdr_color_conversion(std::string_view transfer, bool dolby_profile5) {
    return dolby_profile5 || transfer == "pq" || transfer == "hlg" ||
        transfer == "smpte2084" || transfer == "arib-std-b67";
}

inline bool can_export_decoder_image(bool requested, bool redraw, int rotation,
                                     bool hardware, bool color_conversion) {
    return requested && !redraw && rotation == 0 && hardware && !color_conversion;
}

inline bool layer_video_chain_failed(bool layer, bool software_layer, bool error,
                                     std::string_view prefix, std::string_view message) {
    return layer && !software_layer && error && prefix == "cplayer" &&
        message.find("Could not initialize video chain.") != std::string_view::npos;
}
}
