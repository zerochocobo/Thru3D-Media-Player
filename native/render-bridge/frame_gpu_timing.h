#pragma once
#include <array>
#include <cstdint>
#include <cstddef>

// Nonblocking timestamp pairs around a rendered frame. Unlike TIME_ELAPSED,
// timestamps do not conflict with the existing per-pass video GPU timers.
template <typename Api> class FrameGpuTiming {
    struct Pair { unsigned begin = 0, end = 0; bool pending = false; uint64_t serial = 0; };
    std::array<Pair, 3> pairs{};
    int active = -1;
    uint64_t serial = 0, delivered = 0;
public:
    // >0: a new valid measurement in ms; 0: not ready; -1: invalid/unavailable.
    double begin(Api& api) {
        if (!api.available() || active >= 0) return -1;
        if (api.disjoint()) {
            for (auto& pair : pairs) pair.pending = false;
            return -1;
        }
        double result = 0;
        for (auto& pair : pairs) {
            if (!pair.pending || !api.ready(pair.begin) || !api.ready(pair.end)) continue;
            const auto start = api.result(pair.begin), end = api.result(pair.end);
            pair.pending = false;
            if (end > start && end - start < 250000000 && pair.serial > delivered) {
                delivered = pair.serial;
                result = static_cast<double>(end - start) / 1000000.0;
            }
        }
        // Disjoint can become visible while reading results; never publish those values.
        if (api.disjoint()) { for (auto& pair : pairs) pair.pending = false; return -1; }
        for (std::size_t i = 0; i < pairs.size(); ++i) {
            auto& pair = pairs[i];
            if (pair.pending) continue;
            if (!pair.begin) { pair.begin = api.create(); pair.end = api.create(); }
            if (!pair.begin || !pair.end) return -1;
            api.stamp(pair.begin); active = static_cast<int>(i); pair.serial = ++serial;
            break;
        }
        return result;
    }
    void end(Api& api) {
        if (active < 0) return;
        auto& pair = pairs[static_cast<std::size_t>(active)];
        api.stamp(pair.end); pair.pending = true; active = -1;
    }
    void reset(Api& api, bool destroy = true) {
        for (auto& pair : pairs) {
            if (destroy) { if (pair.begin) api.destroy(pair.begin); if (pair.end) api.destroy(pair.end); }
            pair = {};
        }
        active = -1; serial = delivered = 0;
    }
};

// An EGL context can exist before timer queries become usable (e.g. a sleeping
// headset). Retry unavailable queries and recover an abandoned ring without ever
// inventing a sample or waiting for the GPU. Context names are local to a session.
template <typename Api> class FrameGpuTimingSession {
    FrameGpuTiming<Api> timer;
    uintptr_t context = 0;
    uint64_t retry_at = 0, last_sample_at = 0;
public:
    double update(Api& api, int action, uintptr_t current, uint64_t now_ms) {
        if (action < 0) {
            timer.reset(api, current && context == current && api.available());
            context = 0; retry_at = 0; last_sample_at = 0;
            return 0;
        }
        if (!current) return -1;
        if (context != current) {
            timer.reset(api, false); context = current;
            api.initialize(); retry_at = now_ms + 1000; last_sample_at = now_ms;
        }
        if (!api.available()) {
            if (now_ms >= retry_at) { api.initialize(); retry_at = now_ms + 1000; }
            if (!api.available()) return -1;
        }
        if (action == 0) { timer.end(api); return 0; }
        if (now_ms - last_sample_at >= 1000) {
            // A lost/disjoint interval must not leave all three slots pending forever.
            timer.reset(api); last_sample_at = now_ms;
        }
        const double sample = timer.begin(api);
        if (sample > 0) last_sample_at = now_ms;
        return sample;
    }
};
