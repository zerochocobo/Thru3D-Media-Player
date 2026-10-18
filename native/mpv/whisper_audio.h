#pragma once
#include <algorithm>
#include <cstdint>
#include <cmath>
#include <iomanip>
#include <locale>
#include <sstream>
#include <functional>
#include <string>
#include <utility>
#include <vector>

namespace quest {
// Runs only on MPV's control thread. The filter operates before master volume
// and temporary narration ducking. Channel-linked detection preserves stereo
// balance; bounded makeup never chases silence or gates whispered consonants.
class WhisperAudio {
public:
    using Command = std::function<int(const std::vector<std::string>&)>;
    explicit WhisperAudio(Command command) : command_(std::move(command)) {}
    static const char* graph() {
        return "@thru_whisper:lavfi=[acompressor=threshold=0.0316227766:ratio=6:"
               "attack=5:release=250:makeup=1:knee=2.8284271247:"
               "link=maximum:detection=peak:mix=0,"
               "alimiter=limit=0.95:attack=5:release=80:level=false:latency=true]";
    }
    static bool valid(int level) { return level >= 0 && level <= 51; }
    int level = 0;
    uint64_t serial = 0;
    std::string error;
    bool pending() const { return stage_ != Idle; }

    void request(int target, uint64_t request_serial, int64_t now_ms) {
        if (!valid(target)) return;
        target_ = target; pending_serial_ = request_serial; error.clear();
        if (!installed_ && target == 0) { finish(); return; }
        if (!installed_) {
            if (!run({"af", "add", graph()})) return;
            installed_ = true; mix_ = 0; gain_ = 0; ready_ = false;
        }
        stage_ = target == 0 ? FadeOut : FadeIn;
        start_mix_ = mix_; start_gain_ = gain_;
        started_ = now_ms; last_step_ = now_ms - 15;
    }
    // MPV resets lavfi runtime parameters on seeks and audio reconfiguration.
    void invalidate(int64_t now_ms) {
        if (!installed_) return;
        ready_ = false; waiting_for_play_ = false; ready_since_ = -1;
        last_probe_ = now_ms - 100; mix_ = 0; gain_ = 0;
        stage_ = target_ == 0 ? FadeOut : FadeIn;
        start_mix_ = 0; start_gain_ = 0; started_ = now_ms; last_step_ = now_ms - 15;
    }
    void tick(int64_t now_ms, bool playing = true) {
        if (stage_ == Idle || now_ms - last_step_ < 15) return;
        last_step_ = now_ms;
        if (!ready_) {
            // Removing our filter does not require a configured audio graph.
            if (target_ == 0) {
                if (!run({"af", "remove", "@thru_whisper"})) return;
                installed_ = false; finish(); return;
            }
            if (!playing) ready_since_ = -1;
            if ((!playing && waiting_for_play_) || now_ms - last_probe_ < 100) return;
            last_probe_ = now_ms;
            // af add parses the graph, but af-command works only after MPV
            // receives audio and initializes it. A paused source can wait.
            if (command_({"af-command", "thru_whisper", "mix", "0", "acompressor"}) < 0) {
                waiting_for_play_ = !playing;
                if (playing && ready_since_ < 0) ready_since_ = now_ms;
                if (playing && now_ms - ready_since_ >= 2000) fail();
                return;
            }
            ready_ = true; waiting_for_play_ = false; ready_since_ = -1;
            // Set all parameters while dry; an event may also reuse a graph.
            if (!parameter("threshold", "0.0316227766") || !parameter("ratio", "6") || !parameter("makeup", "1")) return;
            gain_ = 0; start_gain_ = 0; start_mix_ = 0; started_ = now_ms;
        }
        const double t = std::min(1.0, std::max(0.0, (now_ms - started_) / 150.0));
        mix_ = stage_ == FadeIn ? start_mix_ + (1 - start_mix_) * t : start_mix_ * (1 - t);
        const double goal = target_ > 0 ? 14.0 * (target_ - 1) / 50.0 : 0;
        gain_ = stage_ == FadeIn ? start_gain_ + (goal - start_gain_) * t : start_gain_;
        if (!parameter("makeup", decimal(std::pow(10.0, gain_ / 20.0))) || !parameter("mix", decimal(mix_))) return;
        if (t < 1) return;
        if (stage_ == FadeOut) {
            if (!run({"af", "remove", "@thru_whisper"})) return;
            installed_ = false;
        }
        finish();
    }

private:
    enum Stage { Idle, FadeOut, FadeIn } stage_ = Idle;
    Command command_;
    bool installed_ = false;
    bool ready_ = false, waiting_for_play_ = false;
    int target_ = 0;
    uint64_t pending_serial_ = 0;
    int64_t started_ = 0, last_step_ = 0;
    int64_t ready_since_ = -1, last_probe_ = -100;
    double mix_ = 0, start_mix_ = 0, gain_ = 0, start_gain_ = 0;
    void finish() { level = target_; serial = pending_serial_; stage_ = Idle; }
    bool run(const std::vector<std::string>& args) {
        if (command_(args) >= 0) return true;
        fail();
        return false;
    }
    void fail() {
        // An unavailable filter/command must not fail or mute the video.
        command_({"af", "remove", "@thru_whisper"});
        installed_ = false; ready_ = false; waiting_for_play_ = false; ready_since_ = -1;
        mix_ = 0; target_ = 0;
        error = "whisper_filter_unavailable"; finish();
    }
    bool parameter(const std::string& key, const std::string& value) {
        return run({"af-command", "thru_whisper", key, value, "acompressor"});
    }
    static std::string decimal(double value) {
        std::ostringstream stream;
        stream.imbue(std::locale::classic());
        stream << std::fixed << std::setprecision(8) << value;
        return stream.str();
    }
};
} // namespace quest
