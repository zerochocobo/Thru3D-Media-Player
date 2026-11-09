#pragma once
#include <cstddef>
#include <cstdint>
#include <vector>

namespace quest {
// Restore the activation removed by the OpenCL-specific convolution fusion.
// Packaged weights and output tensor identities remain unchanged.
std::vector<uint8_t> rvm_portable_graph(const void* model, size_t bytes);
}
