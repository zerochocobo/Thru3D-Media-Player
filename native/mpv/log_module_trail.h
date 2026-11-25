#pragma once

#include <array>
#include <atomic>
#include <cstdint>
#include <mutex>
#include <string>
#include <string_view>

namespace quest {

/** Recent module names and confirmed decoder milestones seen by the control thread.
 * The diagnostic retains no log message text. */
class LogModuleTrail {
public:
    static constexpr int kSize = 6;
    static constexpr size_t kPrefix = 24;

    void observe(const char* prefix, std::string_view message, int64_t now_us) {
        const std::string module = clean(prefix);
        std::lock_guard<std::mutex> lock(mutex_);
        last_us_ = now_us;
        // Starting a codec and actually decoding with it are separate MPV events.
        // Keep only their labels and the times the control thread observed them.
        if (module == "ffmpeg/video" && message.find("_mediacodec: MediaCodec started successfully:") != std::string_view::npos)
            mediacodec_started_ms_ = now_us / 1000;
        if (module == "vd") {
            if (message.rfind("Using hardware decoding (", 0) == 0) {
                decoder_ = "hardware";
                decoder_observed_ms_ = now_us / 1000;
            } else if (message.rfind("Using software decoding.", 0) == 0) {
                decoder_ = "software";
                decoder_observed_ms_ = now_us / 1000;
            }
        }
        // Repeated lines from one module keep a single entry, so the trail spans module changes.
        if (count_ > 0 && modules_[(next_ + kSize - 1) % kSize] == module) return;
        modules_[next_] = module;
        next_ = (next_ + 1) % kSize;
        if (count_ < kSize) ++count_;
    }

    /** Timings are relative to source creation, except last_log_ms, which is an age.
     * [key] prefixes every field name, so two trails can share one record. */
    std::string json_fields(int64_t now_us, const std::string& key = "") const {
        std::lock_guard<std::mutex> lock(mutex_);
        std::string out = ",\"" + key + "recent_modules\":[";
        for (int i = 0; i < count_; ++i) {
            if (i) out += ',';
            out += '"' + modules_[(next_ + kSize - count_ + i) % kSize] + '"';
        }
        out += "],\"" + key + "last_log_ms\":" + std::to_string(last_us_ < 0 ? -1 : (now_us - last_us_) / 1000);
        out += ",\"" + key + "decoder\":\"" + std::string(decoder_) + "\",\"" + key + "decoder_observed_ms\":" + std::to_string(decoder_observed_ms_);
        out += ",\"" + key + "mediacodec_started_ms\":" + std::to_string(mediacodec_started_ms_);
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
    const char* decoder_ = "unknown";
    int64_t decoder_observed_ms_ = -1, mediacodec_started_ms_ = -1;
};

/** The step the control thread is in, and since when. Its libmpv calls wait for the core thread, so a
 * close that never reaches the loop top names the call blocking it. Labels are fixed literals. */
class ControlCall {
public:
    void enter(const char* label, int64_t now_us) {
        since_us_.store(now_us);
        label_.store(label);
    }

    /** ,"control_call":"label","control_call_ms":N (-1 before the first step). */
    std::string json_fields(int64_t now_us) const {
        const char* label = label_.load();
        const int64_t since = since_us_.load();
        return std::string(",\"control_call\":\"") + label + "\",\"control_call_ms\":" +
            std::to_string(since < 0 ? -1 : (now_us - since) / 1000);
    }

private:
    std::atomic<const char*> label_{"setup"};
    std::atomic<int64_t> since_us_{-1};
};

}  // namespace quest
