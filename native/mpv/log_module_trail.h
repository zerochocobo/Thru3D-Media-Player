#pragma once

#include <array>
#include <cstdint>
#include <mutex>
#include <string>

namespace quest {

/** The MPV log modules a core used last (prefixes only, never message text): when a source stops
 * answering a close, they show whether it was in audio output, a decoder, a demuxer or a stream. */
class LogModuleTrail {
public:
    static constexpr int kSize = 6;
    static constexpr size_t kPrefix = 24;

    void observe(const char* prefix, int64_t now_us) {
        const std::string module = clean(prefix);
        std::lock_guard<std::mutex> lock(mutex_);
        last_us_ = now_us;
        // Repeated lines from one module keep a single entry, so the trail spans module changes.
        if (count_ > 0 && modules_[(next_ + kSize - 1) % kSize] == module) return;
        modules_[next_] = module;
        next_ = (next_ + 1) % kSize;
        if (count_ < kSize) ++count_;
    }

    /** ,"recent_modules":[oldest..newest],"last_log_ms":N (-1 before any log line). */
    std::string json_fields(int64_t now_us) const {
        std::lock_guard<std::mutex> lock(mutex_);
        std::string out = ",\"recent_modules\":[";
        for (int i = 0; i < count_; ++i) {
            if (i) out += ',';
            out += '"' + modules_[(next_ + kSize - count_ + i) % kSize] + '"';
        }
        out += "],\"last_log_ms\":" + std::to_string(last_us_ < 0 ? -1 : (now_us - last_us_) / 1000);
        return out;
    }

    /** Lower-case module names only: anything outside [a-z0-9/_.-] becomes '?', so no text or path leaks. */
    static std::string clean(const char* prefix) {
        std::string out;
        for (const char* p = prefix ? prefix : ""; *p && out.size() < kPrefix; ++p) {
            char c = *p >= 'A' && *p <= 'Z' ? static_cast<char>(*p - 'A' + 'a') : *p;
            out += (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '/' || c == '_' || c == '.' || c == '-' ? c : '?';
        }
        return out.empty() ? "?" : out;
    }

private:
    mutable std::mutex mutex_;
    std::array<std::string, kSize> modules_{};
    int next_ = 0;
    int count_ = 0;
    int64_t last_us_ = -1;
};

}  // namespace quest
