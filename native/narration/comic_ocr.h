#pragma once
#include <cstdint>
#ifdef _WIN32
#define COMIC_EXPORT __declspec(dllexport)
#else
#define COMIC_EXPORT __attribute__((visibility("default")))
#endif
// RGB pixels, already oriented, longest edge <=1600. One page per call.
// Handles are registry IDs, cancellation and destruction are safe during inference.
extern "C" {
COMIC_EXPORT int64_t comic_create(const char* directory);
COMIC_EXPORT void comic_cancel(int64_t handle, int64_t generation);
COMIC_EXPORT const char* comic_analyze(int64_t handle, const uint8_t* rgb, int width, int height, int64_t generation);
COMIC_EXPORT const char* comic_analyze_unrestricted(int64_t handle, const uint8_t* rgb, int width, int height, int64_t generation);
COMIC_EXPORT void comic_destroy(int64_t handle);
COMIC_EXPORT void comic_free(const char* text);
}
