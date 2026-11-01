#pragma once
#include <cstdint>
#ifdef _WIN32
#define TEXT_EXPORT __declspec(dllexport)
#else
#define TEXT_EXPORT __attribute__((visibility("default")))
#endif
// Detection only. Input is canonical top-row RGB CHW [0,1], dimensions aligned to 32.
// Reuses comic_regions connected components and the process's existing ORT environment.
extern "C" {
TEXT_EXPORT int64_t text_detector_create(const char* model);
TEXT_EXPORT void text_detector_cancel(int64_t handle, int64_t generation);
TEXT_EXPORT const char* text_detector_run(int64_t handle, const float* rgb, int width, int height, int64_t generation);
TEXT_EXPORT void text_detector_destroy(int64_t handle);
TEXT_EXPORT void text_detector_free(const char* text);
}
