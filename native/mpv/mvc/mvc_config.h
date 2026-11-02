/* Owned AVC/MVC configuration reader. No FFmpeg ABI or unbounded allocations. */
#ifndef THRU3D_MVC_CONFIG_H
#define THRU3D_MVC_CONFIG_H
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#define THRU_MVC_CONFIG_LIMIT (512 * 1024)
typedef int (*ThruMvcNal)(void *, const uint8_t *, size_t);
typedef struct ThruMvcConfig {
    const uint8_t *avc, *mvc;
    size_t avc_size, mvc_size;
    int length_size, base_right;
} ThruMvcConfig;

static inline uint32_t thru_mvc_be32(const uint8_t *p)
{
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}
static inline void thru_mvc_put32(uint8_t *p, uint32_t n)
{
    p[0] = n >> 24; p[1] = n >> 16; p[2] = n >> 8; p[3] = n;
}

/* Both records start with version/profile/compatibility/level/lengthSize.
 * MVC's SPS array includes subset SPS. Validate all declared parameter sets. */
static inline int thru_mvc_record(const uint8_t *p, size_t size, int mvc,
                                  ThruMvcNal consume, void *opaque, size_t *end)
{
    if (!p || size < 7 || size > THRU_MVC_CONFIG_LIMIT || p[0] != 1 ||
        (p[4] & 0xfc) != 0xfc || (mvc && p[1] != 128)) return -1;
    size_t at = 6;
    int subset = 0;
    unsigned count = mvc ? p[5] : p[5] & 31;
    if (!count) return -1;
    for (int group = 0; group < 2; ++group) {
        for (unsigned i = 0; i < count; ++i) {
            if (at + 2 > size) return -1;
            size_t n = (size_t)p[at] << 8 | p[at + 1]; at += 2;
            if (!n || n > size - at) return -1;
            int type = p[at] & 31;
            if ((!group && type != 7 && !(mvc && type == 15)) || (group && type != 8)) return -1;
            subset |= type == 15;
            if (consume && consume(opaque, p + at, n) < 0) return -1;
            at += n;
        }
        if (!group) {
            if (at >= size || !(count = p[at++])) return -1;
        }
    }
    if (mvc && !subset) return -1;
    /* AVC High-profile extension precedes the legacy MVC extension box. */
    if (!mvc && at + 4 <= size && (p[at] & 0xfc) == 0xfc &&
        (p[at + 1] & 0xf8) == 0xf8 && (p[at + 2] & 0xf8) == 0xf8) {
        count = p[at + 3]; at += 4;
        for (unsigned i = 0; i < count; ++i) {
            if (at + 2 > size) return -1;
            size_t n = (size_t)p[at] << 8 | p[at + 1]; at += 2;
            if (!n || n > size - at || (p[at] & 31) != 13) return -1;
            at += n;
        }
    }
    if (end) *end = at;
    return 0;
}

/* Returns 1 for a validated MVC record, 0 for AVC alone, -1 for bad config.
 * Mapping-only and legacy CodecPrivate forms share this validation. */
static inline int thru_mvc_config(const uint8_t *avc, size_t avc_size,
                                  const uint8_t *mvc, size_t mvc_size,
                                  int base_right, ThruMvcConfig *out)
{
    size_t at;
    memset(out, 0, sizeof(*out));
    out->mvc = mvc;
    if (thru_mvc_record(avc, avc_size, 0, NULL, NULL, &at) < 0) return -1;
    if (!mvc) {
        while (at + 8 <= avc_size) {
            size_t n = thru_mvc_be32(avc + at);
            if (n < 4 || n > avc_size - at - 4) return -1;
            if (!memcmp(avc + at + 4, "mvcC", 4)) {
                mvc = avc + at + 8; mvc_size = n - 4; break;
            }
            at += n + 4;
        }
    }
    if (!mvc) return 0;
    out->mvc = mvc;
    size_t used;
    if (thru_mvc_record(mvc, mvc_size, 1, NULL, NULL, &used) < 0 ||
        used != mvc_size || (mvc[4] & 3) != (avc[4] & 3)) return -1;
    *out = (ThruMvcConfig){avc, mvc, avc_size, mvc_size, (avc[4] & 3) + 1, !!base_right};
    return 1;
}

/* Private, versioned decoder extradata; ISO's existing one-byte eye flag stays
 * unchanged. Lengths are checked before constructing pointers. */
static inline int thru_mvc_unpack(const uint8_t *p, size_t size, ThruMvcConfig *out)
{
    if (!p || size < 16 || memcmp(p, "T3MV", 4) || p[4] != 1 || p[5] > 1 || p[6] || p[7]) return -1;
    size_t a = thru_mvc_be32(p + 8), m = thru_mvc_be32(p + 12);
    if (a > THRU_MVC_CONFIG_LIMIT || m > THRU_MVC_CONFIG_LIMIT || a + m != size - 16) return -1;
    return thru_mvc_config(p + 16, a, p + 16 + a, m, p[5], out) == 1 ? 0 : -1;
}
#endif
