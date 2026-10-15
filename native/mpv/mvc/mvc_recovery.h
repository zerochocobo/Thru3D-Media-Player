/* Blu-ray open-GOP recovery gate. Owned adapter code, LGPL-2.1-or-later. */
#ifndef THRU3D_MVC_RECOVERY_H
#define THRU3D_MVC_RECOVERY_H
#include <stdint.h>
#include <stddef.h>
#include <limits.h>

struct Edge264MvcDecoder;
int thru3d_mvc_base_picture(struct Edge264MvcDecoder *dec, int *frame_num, int *mask, int *reference);

typedef struct MvcRecovery {
    int pending, target, ready;
    int64_t first_pts;
} MvcRecovery;

static inline void mvc_recovery_reset(MvcRecovery *s)
{
    s->pending = s->target = -1;
    s->ready = 0;
    s->first_pts = INT64_MAX;
}

typedef struct MvcRbsp {
    const uint8_t *data;
    size_t size, next;
    int zeros;
} MvcRbsp;

static inline int mvc_rbsp_byte(MvcRbsp *s)
{
    if (s->next >= s->size) return -1;
    int byte = s->data[s->next++];
    if (s->zeros == 2 && byte == 3) {
        if (s->next >= s->size || s->data[s->next] > 3) return -1;
        byte = s->data[s->next++];
        s->zeros = 0;
    }
    s->zeros = byte == 0 ? s->zeros + 1 : 0;
    return byte;
}

/* Parse SEI payload type 6, not the NAL type (also 6). No allocation, and all
   lengths are bounded by the NAL. Skip unrelated messages and Annex B escapes. */
static inline int mvc_recovery_sei(const uint8_t *data, size_t size, int *count)
{
    MvcRbsp rbsp = {data, size, 0, 0};
    int found = -1;
    while (rbsp.next < rbsp.size) {
        int byte = mvc_rbsp_byte(&rbsp);
        if (byte < 0) return 0;
        if (byte == 0x80 && rbsp.next == rbsp.size) break;
        unsigned type = 0, bytes = 0;
        for (;;) {
            if (type > UINT_MAX - (unsigned)byte) return 0;
            type += byte;
            if (byte != 255) break;
            if ((byte = mvc_rbsp_byte(&rbsp)) < 0) return 0;
        }
        do {
            if ((byte = mvc_rbsp_byte(&rbsp)) < 0 || bytes > UINT_MAX - (unsigned)byte) return 0;
            bytes += byte;
        } while (byte == 255);
        if (bytes > rbsp.size - rbsp.next) return 0;
        uint64_t bits = 0;
        unsigned used = 0;
        for (unsigned i = 0; i < bytes; i++) {
            if ((byte = mvc_rbsp_byte(&rbsp)) < 0) return 0;
            if (used < 8) { bits = bits << 8 | byte; used++; }
        }
        if (type == 6) {
            unsigned zeros = 0, available = used * 8;
            while (zeros < available && !(bits >> (available - zeros - 1) & 1)) zeros++;
            /* recovery_frame_cnt <= 65535, followed by four flag bits. */
            if (zeros > 16 || 2 * zeros + 5 > available) return 0;
            found = ((1U << zeros) - 1) +
                ((bits >> (available - 2 * zeros - 1)) & ((1U << zeros) - 1));
            if (found > 65535) return 0;
        }
    }
    *count = found;
    return 1;
}

/* frame_num counts reference pictures, not presentation frames. In particular,
   counting returned stereo pairs is wrong for B pictures and frame_num wrap. */
static inline void mvc_recovery_picture(MvcRecovery *s, int frame_num, int mask,
                                        int idr, int reference, int64_t pts)
{
    if (s->ready || pts == INT64_MIN) return;
    if (idr) {
        s->ready = 1; s->first_pts = pts;
        return;
    }
    if (s->pending >= 0) {
        s->target = (frame_num + s->pending) & mask;
        s->pending = -1;
    }
    if (reference && s->target == frame_num) {
        s->ready = 1; s->first_pts = pts;
    }
}

static inline int mvc_recovery_allows(const MvcRecovery *s, int64_t pts)
{
    return s->ready && pts >= s->first_pts;
}
#endif
