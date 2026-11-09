#pragma once
#include <MNN/Interpreter.hpp>
#include <stdexcept>
#include <cstdlib>
#if defined(__ANDROID__)
#include <sys/system_properties.h>
#endif

namespace quest {
// Capability selection is shared by depth, portrait, photos and browser workers.
// Keep working OpenCL devices unchanged; never treat MNN's CPU backup as a GPU.
inline MNNForwardType mnn_gpu_backend() {
    static const MNNForwardType selected = [] {
        for (auto type : {MNN_FORWARD_OPENCL, MNN_FORWARD_VULKAN}) {
            MNN::ScheduleConfig config;
            config.type = type;
            config.numThread = MNN_GPU_TUNING_NONE;
            const auto runtime = MNN::Interpreter::createRuntime({config});
            const auto found = runtime.first.find(type);
            if (found != runtime.first.end() && found->second) return type;
        }
        throw std::runtime_error("AI GPU unavailable: OpenCL and Vulkan initialization failed; refusing CPU execution");
    }();
    return selected;
}
inline bool mnn_uses_vulkan() { return mnn_gpu_backend() == MNN_FORWARD_VULKAN; }
// Reuse one command buffer and tune the measured video profiles. Larger still-photo
// graphs retain the conservative mode until their startup/throughput is measured.
// The diagnostic override compares only valid Vulkan modes; never changes precision/backend.
inline int mnn_vulkan_mode(bool tune_video = true) {
#if defined(__ANDROID__)
    char value[PROP_VALUE_MAX] = {};
    if (__system_property_get("debug.vrpp.vulkan.gpumode", value) > 0) {
        const int mode = std::atoi(value);
        if (mode == MNN_GPU_TUNING_NONE || mode == MNN_GPU_TUNING_WIDE ||
            mode == (MNN_GPU_TUNING_NONE | MNN_GPU_RECORD_BATCH) ||
            mode == (MNN_GPU_TUNING_WIDE | MNN_GPU_RECORD_BATCH)) return mode;
    }
#endif
    return tune_video ? MNN_GPU_TUNING_WIDE | MNN_GPU_RECORD_BATCH : MNN_GPU_TUNING_NONE;
}
} // namespace quest
