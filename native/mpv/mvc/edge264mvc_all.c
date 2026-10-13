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
