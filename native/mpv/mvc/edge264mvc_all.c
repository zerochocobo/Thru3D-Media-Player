/* Compiles the pinned BSD decoder into libavcodec without another runtime DLL. */
#include <stdlib.h>
#if defined(__ANDROID__) && __ANDROID_API__ < 28
static inline void *thru3d_mvc_aligned_alloc(size_t alignment, size_t size)
{
    void *memory = NULL;
    if (!alignment || size % alignment || posix_memalign(&memory, alignment, size))
        return NULL;
    return memory;
}
#define aligned_alloc thru3d_mvc_aligned_alloc
#endif
#include "edge264mvc/src/edge264mvc.c"
#include "mvc_recovery.h"

/* The public API exposes POC but not H.264 frame_num. Read the parser's base
   picture state on its owner thread, after send_nal accepted a base slice.
   Worker-owned pixel/flags data is untouched. Keep this pin-specific access here. */
int thru3d_mvc_base_picture(Edge264MvcDecoder *dec, int *frame_num, int *mask, int *reference)
{
    if (dec->currPic < 0 || (dec->non_base_frames & (FrameMask)1 << dec->currPic) ||
        dec->sps.log2_max_frame_num < 4 || dec->sps.log2_max_frame_num > 16)
        return 0;
    *mask = (1 << dec->sps.log2_max_frame_num) - 1;
    *frame_num = dec->FrameNum & *mask;
    *reference = dec->currPic_reference;
    return 1;
}
