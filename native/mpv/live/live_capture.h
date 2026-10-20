#pragma once
#include <cstdint>
struct mpv_handle;
namespace quest::live {
uint64_t source_open(mpv_handle*) noexcept;
void source_close(uint64_t);
bool supported();
}
