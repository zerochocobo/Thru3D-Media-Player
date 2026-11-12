// ETC2 texture encoder for imported scenes: decoded glTF textures are four times the size of
// GPU-compressed ones, and the engine cannot compress at run time on a headset.
// Fast and plain: ETC1-compatible colour blocks (individual / differential) and EAC alpha.
#pragma once
#include <cstddef>
#include <cstdint>

#ifdef __cplusplus
extern "C" {
#endif

// Bytes needed for one level: 8 per 4x4 block, 16 with alpha (ETC2 RGBA8).
size_t thru3d_etc2_level_size(int width, int height, int alpha);

// Bytes of a full chain from width x height down to 1x1 (levels halve, never below 1).
size_t thru3d_etc2_chain_size(int width, int height, int alpha);
size_t thru3d_rgba_chain_size(int width, int height);

// Encodes tightly packed RGBA8 pixels. With `chain` non-zero the input holds every level down
// to 1x1 back to back and the output holds every encoded level the same way.
// Returns 0 on success; nothing is written past `out_size`.
int thru3d_etc2_encode(const uint8_t* rgba, size_t rgba_size, int width, int height, int alpha, int chain,
                       uint8_t* out, size_t out_size, int threads);

#ifdef __cplusplus
}
#endif
