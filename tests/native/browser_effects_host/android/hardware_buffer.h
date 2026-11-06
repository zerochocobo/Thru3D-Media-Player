#pragma once
#define AHARDWAREBUFFER_USAGE_GPU_FRAMEBUFFER (1ULL << 9)
#define AHARDWAREBUFFER_USAGE_CPU_READ_RARELY 2ULL
#define AHARDWAREBUFFER_USAGE_CPU_WRITE_RARELY (2ULL << 4)
#include <cstdint>
struct AHardwareBuffer {};
struct AHardwareBuffer_Desc { uint32_t width,height,layers,format; uint64_t usage; uint32_t stride,rfu0; uint64_t rfu1; };
enum { AHARDWAREBUFFER_FORMAT_R8G8B8A8_UNORM=1, AHARDWAREBUFFER_USAGE_CPU_READ_OFTEN=3, AHARDWAREBUFFER_USAGE_CPU_WRITE_OFTEN=48,
       AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE=256, AHARDWAREBUFFER_USAGE_GPU_COLOR_OUTPUT=512 };
inline int AHardwareBuffer_allocate(const AHardwareBuffer_Desc*,AHardwareBuffer**) { return -1; }
inline void AHardwareBuffer_acquire(AHardwareBuffer*) {}
inline void AHardwareBuffer_release(AHardwareBuffer*) {}
