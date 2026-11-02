#include "../../native/mpv/mkv_mvc_probe.h"
#include <cstdio>
#include <cstdlib>

int main(int argc, char **argv) {
    if (argc < 2 || argc > 3) return 2;
    try {
        const int timeout = argc == 3 ? std::atoi(argv[2]) : 45000;
        if (timeout <= 0 || timeout > 45000) return 2;
        quest::DiscProbe control(quest::DiscProbe::Clock::now() + std::chrono::milliseconds(timeout));
        auto result = quest::probe_mkv_mvc(argv[1], "", control);
        std::printf("{\"mvc\":%s,\"width\":%d,\"height\":%d,\"header_bytes\":%lld}\n",
            result.mvc ? "true" : "false", result.width, result.height, static_cast<long long>(result.read_bytes));
        return 0;
    } catch (const std::exception& error) {
        std::fprintf(stderr, "%s\n", error.what()); return 1;
    }
}
