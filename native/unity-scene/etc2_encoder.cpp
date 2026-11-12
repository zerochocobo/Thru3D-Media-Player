#include "etc2_encoder.h"

#include <algorithm>
#include <climits>
#include <cstring>
#include <thread>
#include <vector>

namespace {

const int kModifiers[8][2] = {{2, 8}, {5, 17}, {9, 29}, {13, 42}, {18, 60}, {24, 80}, {33, 106}, {47, 183}};
const int kAlphaTables[16][8] = {
    {-3, -6, -9, -15, 2, 5, 8, 14}, {-3, -7, -10, -13, 2, 6, 9, 12}, {-2, -5, -8, -13, 1, 4, 7, 12}, {-2, -4, -6, -13, 1, 3, 5, 12},
    {-3, -6, -8, -12, 2, 5, 7, 11}, {-3, -7, -9, -11, 2, 6, 8, 10}, {-4, -7, -8, -11, 3, 6, 7, 10}, {-3, -5, -8, -11, 2, 4, 7, 10},
    {-2, -6, -8, -10, 1, 5, 7, 9},  {-2, -5, -8, -10, 1, 4, 7, 9},  {-2, -4, -8, -10, 1, 3, 7, 9},  {-2, -5, -7, -10, 1, 4, 6, 9},
    {-3, -4, -7, -10, 2, 3, 6, 9},  {-1, -2, -3, -10, 0, 1, 2, 9},  {-4, -6, -8, -9, 3, 5, 7, 8},   {-3, -5, -7, -9, 2, 4, 6, 8}};

inline int clamp255(int value) { return value < 0 ? 0 : value > 255 ? 255 : value; }

// Pixels of a block arrive column-major (index = x * 4 + y), the order the format numbers them.
struct Block { uint8_t rgba[16][4]; };

struct Half {
    int base[3];        // expanded 8-bit base colour
    int table = 0;
    uint8_t index[8];   // per pixel: bit1 = negative, bit0 = large
    long error = 0;
};

// Best modifier table and per-pixel choices for the eight pixels of one half block.
void fit_half(const Block& block, const int* pixels, Half& half) {
    half.error = LONG_MAX;
    for (int table = 0; table < 8; table++) {
        long total = 0;
        uint8_t choice[8];
        for (int p = 0; p < 8 && total < half.error; p++) {
            const uint8_t* colour = block.rgba[pixels[p]];
            long best = LONG_MAX;
            for (int m = 0; m < 4; m++) {
                int delta = kModifiers[table][m & 1] * ((m & 2) ? -1 : 1);
                long error = 0;
                for (int c = 0; c < 3; c++) {
                    int difference = clamp255(half.base[c] + delta) - colour[c];
                    error += difference * difference;
                }
                if (error < best) { best = error; choice[p] = uint8_t(m); }
            }
            total += best;
        }
        if (total < half.error) {
            half.error = total;
            half.table = table;
            std::memcpy(half.index, choice, 8);
        }
    }
}

void encode_colour(const Block& block, uint8_t* out) {
    long best_error = LONG_MAX;
    uint8_t best[8] = {};
    for (int flip = 0; flip < 2; flip++) {
        int pixels[2][8];
        int count[2] = {0, 0};
        for (int i = 0; i < 16; i++) {
            int x = i >> 2, y = i & 3;
            int side = flip ? (y >= 2) : (x >= 2);
            pixels[side][count[side]++] = i;
        }
        int sum[2][3] = {};
        for (int side = 0; side < 2; side++)
            for (int p = 0; p < 8; p++)
                for (int c = 0; c < 3; c++) sum[side][c] += block.rgba[pixels[side][p]][c];
        // Differential when the two halves are close enough for 5 bits + a 3-bit step.
        int five[2][3], four[2][3];
        bool differential = true;
        for (int side = 0; side < 2; side++)
            for (int c = 0; c < 3; c++) {
                int average = (sum[side][c] + 4) / 8;
                five[side][c] = (average * 31 + 127) / 255;
                four[side][c] = (average * 15 + 127) / 255;
            }
        for (int c = 0; c < 3; c++) {
            int step = five[1][c] - five[0][c];
            if (step < -4 || step > 3) differential = false;
        }
        Half half[2];
        for (int side = 0; side < 2; side++) {
            for (int c = 0; c < 3; c++)
                half[side].base[c] = differential ? (five[side][c] << 3 | five[side][c] >> 2) : four[side][c] * 17;
            fit_half(block, pixels[side], half[side]);
        }
        long error = half[0].error + half[1].error;
        if (error >= best_error) continue;
        best_error = error;
        uint8_t bytes[8] = {};
        for (int c = 0; c < 3; c++)
            bytes[c] = differential ? uint8_t(five[0][c] << 3 | ((five[1][c] - five[0][c]) & 7)) : uint8_t(four[0][c] << 4 | four[1][c]);
        bytes[3] = uint8_t(half[0].table << 5 | half[1].table << 2 | (differential ? 2 : 0) | flip);
        uint32_t bits = 0;
        for (int side = 0; side < 2; side++)
            for (int p = 0; p < 8; p++) {
                int pixel = pixels[side][p], choice = half[side].index[p];
                if (choice & 2) bits |= 1u << (16 + pixel);
                if (choice & 1) bits |= 1u << pixel;
            }
        bytes[4] = uint8_t(bits >> 24); bytes[5] = uint8_t(bits >> 16); bytes[6] = uint8_t(bits >> 8); bytes[7] = uint8_t(bits);
        std::memcpy(best, bytes, 8);
    }
    std::memcpy(out, best, 8);
}

void encode_alpha(const Block& block, uint8_t* out) {
    int low = 255, high = 0;
    for (const auto& pixel : block.rgba) { low = std::min<int>(low, pixel[3]); high = std::max<int>(high, pixel[3]); }
    int best_base = low, best_multiplier = 1, best_table = 13;
    uint8_t best_index[16];
    std::memset(best_index, 4, 16);   // table 13, entry 4 is +0: an exact flat block
    if (low != high) {
        long best_error = LONG_MAX;
        int base = (low + high + 1) / 2;
        for (int table = 0; table < 16; table++) {
            int span = kAlphaTables[table][7] - kAlphaTables[table][3];
            int centre = (high - low + span / 2) / span;
            for (int multiplier = std::max(1, centre - 1); multiplier <= std::min(15, centre + 1); multiplier++) {
                long total = 0;
                uint8_t index[16];
                for (int p = 0; p < 16 && total < best_error; p++) {
                    long best = LONG_MAX;
                    for (int i = 0; i < 8; i++) {
                        int difference = clamp255(base + kAlphaTables[table][i] * multiplier) - block.rgba[p][3];
                        if (long(difference) * difference < best) { best = long(difference) * difference; index[p] = uint8_t(i); }
                    }
                    total += best;
                }
                if (total < best_error) {
                    best_error = total; best_base = base; best_multiplier = multiplier; best_table = table;
                    std::memcpy(best_index, index, 16);
                }
            }
        }
    }
    out[0] = uint8_t(best_base);
    out[1] = uint8_t(best_multiplier << 4 | best_table);
    uint64_t bits = 0;
    for (int p = 0; p < 16; p++) bits = bits << 3 | best_index[p];
    for (int i = 0; i < 6; i++) out[2 + i] = uint8_t(bits >> (40 - 8 * i));
}

void encode_rows(const uint8_t* rgba, int width, int height, int alpha, uint8_t* out, int first_row, int last_row) {
    int columns = (width + 3) / 4;
    size_t block_bytes = alpha ? 16 : 8;
    for (int by = first_row; by < last_row; by++)
        for (int bx = 0; bx < columns; bx++) {
            Block block;
            for (int x = 0; x < 4; x++)
                for (int y = 0; y < 4; y++) {
                    // Edge blocks of odd sizes repeat the last row and column.
                    int sx = std::min(bx * 4 + x, width - 1), sy = std::min(by * 4 + y, height - 1);
                    std::memcpy(block.rgba[x * 4 + y], rgba + (size_t(sy) * size_t(width) + size_t(sx)) * 4, 4);
                }
            uint8_t* at = out + (size_t(by) * size_t(columns) + size_t(bx)) * block_bytes;
            if (alpha) { encode_alpha(block, at); at += 8; }
            encode_colour(block, at);
        }
}

void encode_level(const uint8_t* rgba, int width, int height, int alpha, uint8_t* out, int threads) {
    int rows = (height + 3) / 4;
    int workers = std::max(1, std::min(threads, rows / 8));
    if (workers == 1) { encode_rows(rgba, width, height, alpha, out, 0, rows); return; }
    std::vector<std::thread> pool;
    for (int w = 0; w < workers; w++)
        pool.emplace_back(encode_rows, rgba, width, height, alpha, out, rows * w / workers, rows * (w + 1) / workers);
    for (std::thread& worker : pool) worker.join();
}

bool usable(int width, int height) { return width > 0 && height > 0 && width <= 16384 && height <= 16384; }

}  // namespace

size_t thru3d_etc2_level_size(int width, int height, int alpha) {
    if (!usable(width, height)) return 0;
    return size_t((width + 3) / 4) * size_t((height + 3) / 4) * (alpha ? 16 : 8);
}

size_t thru3d_etc2_chain_size(int width, int height, int alpha) {
    if (!usable(width, height)) return 0;
    size_t total = 0;
    for (;;) {
        total += thru3d_etc2_level_size(width, height, alpha);
        if (width == 1 && height == 1) return total;
        width = std::max(width / 2, 1); height = std::max(height / 2, 1);
    }
}

size_t thru3d_rgba_chain_size(int width, int height) {
    if (!usable(width, height)) return 0;
    size_t total = 0;
    for (;;) {
        total += size_t(width) * size_t(height) * 4;
        if (width == 1 && height == 1) return total;
        width = std::max(width / 2, 1); height = std::max(height / 2, 1);
    }
}

int thru3d_etc2_encode(const uint8_t* rgba, size_t rgba_size, int width, int height, int alpha, int chain,
                       uint8_t* out, size_t out_size, int threads) {
    if (!rgba || !out || !usable(width, height)) return 1;
    size_t need_in = chain ? thru3d_rgba_chain_size(width, height) : size_t(width) * size_t(height) * 4;
    size_t need_out = chain ? thru3d_etc2_chain_size(width, height, alpha) : thru3d_etc2_level_size(width, height, alpha);
    if (rgba_size < need_in || out_size < need_out) return 1;
    try {
        for (;;) {
            encode_level(rgba, width, height, alpha, out, std::max(threads, 1));
            if (!chain || (width == 1 && height == 1)) return 0;
            rgba += size_t(width) * size_t(height) * 4;
            out += thru3d_etc2_level_size(width, height, alpha);
            width = std::max(width / 2, 1); height = std::max(height / 2, 1);
        }
    } catch (...) {
        return 1;   // thread creation failed
    }
}
