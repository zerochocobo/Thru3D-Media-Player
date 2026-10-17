#pragma once
#include <algorithm>
#include <cstdint>

namespace moss {
// PCG XSL-RR 128/64. Fixed state/increment are NumPy default_rng(1234)'s
// seed sequence, matching the previously reviewed native benchmark draws.
class Pcg64 {
    using Wide=unsigned __int128;
    Wide state=(Wide(0x160ad84006fe21eaULL)<<64)|0xf69b873d9fe45409ULL;
public:
    float next() {
        constexpr Wide multiplier=(Wide(0x2360ed051fc65da4ULL)<<64)|0x4385df649fccf645ULL;
        constexpr Wide increment=(Wide(0x50c8fb163c7cea4eULL)<<64)|0xd0f51ce6006e4325ULL;
        state=state*multiplier+increment;
        uint64_t x=uint64_t((state>>64)^state);unsigned rotation=unsigned(state>>122);
        uint64_t bits=(x>>rotation)|(x<<((-rotation)&63));
        return float(std::min(double(bits>>11)*0x1.0p-53,0.99999994));
    }
};
}
