#include "../../native/mpv/disc_probe.h"
#include <cassert>
#include <future>
#include <thread>

int main() {
    quest::DiscProbes jobs;
    const auto first = jobs.begin();
    auto pending = jobs.get(first);
    assert(!quest::DiscProbe::interrupt(pending.get()));
    auto worker = std::async(std::launch::async, [&] {
        // Model an FFmpeg read polling its interrupt callback on the source
        // worker. Closing must not need that worker to run another task.
        while (!quest::DiscProbe::interrupt(pending.get())) std::this_thread::yield();
        return true;
    });
    jobs.close(first);
    assert(worker.wait_for(std::chrono::seconds(1)) == std::future_status::ready);
    assert(worker.get());
    jobs.close(first);
    bool rejected = false;
    try { jobs.get(first); } catch (const std::runtime_error&) { rejected = true; }
    assert(rejected);
    // A stale cancellation cannot cancel the next disc, even across many opens.
    for (int i = 0; i < 100; i++) {
        const auto next = jobs.begin();
        assert(next > first);
        auto healthy = jobs.get(next);
        jobs.close(first);
        assert(!quest::DiscProbe::interrupt(healthy.get()));
        jobs.close(next);
        assert(quest::DiscProbe::interrupt(healthy.get()));
    }
    quest::DiscProbe expired(quest::DiscProbe::Clock::now() - std::chrono::seconds(1));
    assert(quest::DiscProbe::interrupt(&expired));
}
