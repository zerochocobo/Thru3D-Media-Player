#include "../../native/mpv/whisper_audio.h"
#include <cassert>
#include <cmath>
#include <iostream>

int main() {
    std::vector<std::vector<std::string>> calls;
    bool reject = false;
    quest::WhisperAudio filter([&](const auto& args) { calls.push_back(args); return reject ? -1 : 0; });
    auto advance = [&](int start, int end) { for (int t = start; t <= end; t += 15) filter.tick(t); };
    auto last_makeup = [&]() {
        for (auto it = calls.rbegin(); it != calls.rend(); ++it)
            if (it->size() == 5 && (*it)[2] == "makeup") return std::stod((*it)[3]);
        return -1.0;
    };
    assert(!quest::WhisperAudio::valid(-1) && !quest::WhisperAudio::valid(52));
    filter.request(0, 1, 0); assert(calls.empty() && filter.serial == 1);
    filter.request(1, 2, 0); advance(0, 165);
    assert(filter.level == 1 && filter.serial == 2 && std::abs(last_makeup() - 1) < 1e-7);
    size_t from = calls.size();
    filter.request(51, 3, 200); advance(200, 365);
    assert(filter.level == 51 && filter.serial == 3 && std::abs(last_makeup() - std::pow(10.0, 14.0 / 20)) < 1e-7);
    for (size_t i = from; i < calls.size(); ++i) {
        if (calls[i].size() == 5 && calls[i][2] == "mix") assert(calls[i][3] == "1.00000000");
    }
    from = calls.size(); filter.request(26, 4, 400); advance(400, 565);
    assert(filter.level == 26 && filter.serial == 4 && std::abs(last_makeup() - std::pow(10.0, 7.0 / 20)) < 1e-7);
    double previous = 100;
    for (size_t i = from; i < calls.size(); ++i) {
        if (calls[i].size() == 5 && calls[i][2] == "makeup") {
            double gain = std::stod(calls[i][3]); assert(gain <= previous); previous = gain;
        }
        assert(calls[i][0] != "af"); // Continuous changes never rebuild the graph.
    }
    filter.request(0, 5, 600); advance(600, 660);
    filter.request(51, 6, 675); advance(675, 855);
    assert(filter.level == 51 && filter.serial == 6);
    filter.request(1, 7, 900); advance(900, 1080);
    assert(filter.level == 1 && last_makeup() == 1); // Compression stays enabled below 100%.
    assert(std::count_if(calls.begin(), calls.end(), [](const auto& c) { return c[0] == "af" && c[1] == "add"; }) == 1);
    filter.request(0, 8, 1100); advance(1100, 1280);
    assert(filter.level == 0 && filter.serial == 8 && calls.back() == std::vector<std::string>({"af", "remove", "@thru_whisper"}));
    reject = true; filter.request(1, 9, 1300);
    assert(filter.level == 0 && filter.serial == 9 && !filter.error.empty());
    reject = false;
    for (int strength = 1; strength <= 51; ++strength) {
        filter.request(strength, 10 + strength, 1400 + strength * 15);
        filter.tick(1400 + strength * 15);
    }
    advance(2180, 2380);
    assert(filter.level == 51 && filter.serial == 61 && filter.error.empty());
    bool initialized = false;
    std::vector<std::vector<std::string>> deferred_calls;
    quest::WhisperAudio deferred([&](const auto& args) {
        deferred_calls.push_back(args); return args[0] == "af-command" && !initialized ? -1 : 0;
    });
    deferred.request(38, 1, 0);
    for (int t = 0; t < 10000; t += 15) deferred.tick(t, false);
    assert(deferred.pending() && deferred.serial == 0 && deferred.error.empty() && deferred_calls.size() == 2);
    initialized = true;
    for (int t = 10000; t <= 10360; t += 15) deferred.tick(t);
    assert(deferred.level == 38 && deferred.serial == 1 && !deferred.pending());
    initialized = false; deferred.invalidate(11000);
    for (int t = 11000; t <= 12000; t += 15) deferred.tick(t);
    assert(deferred.pending() && deferred.error.empty());
    initialized = true;
    for (int t = 12050; t <= 12500; t += 15) deferred.tick(t);
    assert(deferred.level == 38 && deferred.serial == 1 && !deferred.pending());
    initialized = false; deferred.invalidate(13000); deferred.request(0, 2, 13000); deferred.tick(13000, false);
    assert(deferred.level == 0 && deferred.serial == 2 && !deferred.pending());
    deferred.request(1, 3, 14000);
    for (int t = 14000; t <= 16300; t += 15) deferred.tick(t);
    assert(deferred.level == 0 && deferred.serial == 3 && !deferred.error.empty());
    for (const auto& call : calls) {
        assert(call[0] == "af" || call[0] == "af-command");
        if (call.size() == 5) assert(call[3].find(',') == std::string::npos);
    }
    std::cout << "Continuous boost transitions, unity at 100%, coalescing, reset and failure recovery passed\n";
}
