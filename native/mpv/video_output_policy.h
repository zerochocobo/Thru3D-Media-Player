#pragma once
#include <string_view>

namespace quest {
inline bool layer_video_chain_failed(bool layer, bool software_layer, bool error,
                                     std::string_view prefix, std::string_view message) {
    return layer && !software_layer && error && prefix == "cplayer" &&
        message.find("Could not initialize video chain.") != std::string_view::npos;
}
}
