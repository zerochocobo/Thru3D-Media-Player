#pragma once
#include <cstdint>
#include <functional>
#include <string>
#include <vector>
namespace usb {
using ReadAt = std::function<bool(uint64_t, void*, size_t)>;
struct Entry { std::string name; bool directory; uint64_t size; };
uint64_t mount(ReadAt read, uint64_t length, unsigned sector, bool ntfs);
std::vector<Entry> list(uint64_t volume, const std::string& path);
uint64_t open(uint64_t volume, const std::string& path);
uint64_t size(uint64_t file);
size_t read(uint64_t file, uint64_t offset, void* data, size_t length);
void close_file(uint64_t file);
void close_volume(uint64_t volume);
uint64_t rejected_writes();
}
