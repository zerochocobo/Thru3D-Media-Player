#pragma once
#include <atomic>
#include <chrono>
#include <cstdint>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <unordered_map>

namespace quest {
// A probe owns no decoder or GL objects. Cancellation must remain callable while
// FFmpeg is blocked on the source worker; never share that worker's locks.
struct DiscProbe {
    using Clock = std::chrono::steady_clock;
    std::atomic<bool> cancelled{false};
    const Clock::time_point deadline;
    explicit DiscProbe(Clock::time_point end = Clock::now() + std::chrono::seconds(45)) : deadline(end) {}
    static int interrupt(void* opaque) {
        auto& probe = *static_cast<DiscProbe*>(opaque);
        return probe.cancelled.load() || Clock::now() >= probe.deadline;
    }
};

class DiscProbes {
    std::mutex mutex;
    int64_t sequence = 0;
    std::unordered_map<int64_t, std::shared_ptr<DiscProbe>> probes;
public:
    int64_t begin() {
        std::lock_guard<std::mutex> lock(mutex);
        if (sequence == INT64_MAX || probes.size() >= 16) throw std::runtime_error("Blu-ray probe capacity exhausted");
        const auto id = ++sequence;
        probes.emplace(id, std::make_shared<DiscProbe>());
        return id;
    }
    std::shared_ptr<DiscProbe> get(int64_t id) {
        std::lock_guard<std::mutex> lock(mutex);
        const auto it = probes.find(id);
        if (it == probes.end()) throw std::runtime_error("Blu-ray probe cancelled");
        return it->second;
    }
    void close(int64_t id) {
        std::lock_guard<std::mutex> lock(mutex);
        const auto it = probes.find(id);
        if (it == probes.end()) return;
        it->second->cancelled.store(true);
        probes.erase(it); // A running callback keeps its own shared reference.
    }
};
}
