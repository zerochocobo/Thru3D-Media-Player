#include "../../native/render-bridge/frame_gpu_timing.h"
#include <iostream>
#include <map>
#include <stdexcept>

struct Api {
    struct Query { uint64_t value = 0; bool ready = false; };
    bool supported = true, invalid = false;
    bool capable = true;
    int initializations = 0;
    unsigned next = 0;
    int reads = 0, stamps = 0, deletes = 0;
    uint64_t clock = 1000000;
    std::map<unsigned, Query> queries;
    bool available() { return supported; }
    void initialize() { supported = capable; ++initializations; }
    bool disjoint() { const bool value = invalid; invalid = false; return value; }
    unsigned create() { queries[++next] = {}; return next; }
    void destroy(unsigned id) { queries.erase(id); ++deletes; }
    void stamp(unsigned id) { queries[id] = {clock,false}; ++stamps; }
    bool ready(unsigned id) { return queries.at(id).ready; }
    uint64_t result(unsigned id) {
        if (!ready(id)) throw std::runtime_error("Blocking result read attempted");
        ++reads; return queries.at(id).value;
    }
    void complete() { for (auto& item : queries) item.second.ready = true; }
};

int main() {
    int checks = 0;
    auto check = [&](bool ok, const char* message) { ++checks; if (!ok) throw std::runtime_error(message); };
    try {
        Api api; FrameGpuTiming<Api> timer;
        check(timer.begin(api) == 0, "No invented initial GPU sample");
        api.clock += 3000000; timer.end(api);
        check(timer.begin(api) == 0 && api.reads == 0, "Pending queries are not read synchronously");
        api.clock += 4000000; timer.end(api);
        check(timer.begin(api) == 0, "A third frame can be submitted without waiting");
        api.clock += 5000000; timer.end(api);
        const auto stamps = api.stamps;
        check(timer.begin(api) == 0 && api.stamps == stamps && api.next == 6, "A full ring skips measurement without blocking or overwriting");
        api.complete();
        check(timer.begin(api) == 5.0 && api.reads == 6, "The newest complete pair is measured in milliseconds");
        api.clock += 2000000; timer.end(api); api.complete();
        check(timer.begin(api) == 2.0, "New samples replace older frame durations");
        api.clock += 1000000; timer.end(api); api.invalid = true;
        check(timer.begin(api) < 0, "Disjoint GPU clocks reject the sample");
        check(timer.begin(api) == 0, "A disjoint interval cannot reappear as valid");
        api.clock -= 1; timer.end(api); api.complete();
        check(timer.begin(api) == 0, "Backwards GPU clocks cannot become huge positive durations");
        api.clock += 300000000; timer.end(api); api.complete();
        check(timer.begin(api) == 0, "Invalid or suspended frame durations are discarded");
        timer.end(api); timer.reset(api);
        check(api.queries.empty() && api.deletes == 6, "Stopping releases every owned query");
        api.supported = false;
        check(timer.begin(api) < 0 && api.queries.empty(), "Unsupported hardware never allocates or fabricates a sample");
        api.supported = true; timer.begin(api); timer.end(api);
        const auto deleted = api.deletes; timer.reset(api,false);
        check(api.deletes == deleted, "A context change does not delete another context's objects");
        Api resumed; resumed.capable = false;
        FrameGpuTimingSession<Api> session;
        check(session.update(resumed,1,1,0) < 0 && resumed.initializations == 1,
            "A context with unavailable initial timers remains fail-closed");
        resumed.capable = true;
        check(session.update(resumed,1,1,999) < 0 && resumed.initializations == 1,
            "Unavailable timers retry at most once per second");
        check(session.update(resumed,1,1,1000) == 0 && resumed.initializations == 2,
            "A resumed context can retry capability initialization");
        resumed.clock += 2000000; session.update(resumed,0,1,1001); resumed.complete();
        check(session.update(resumed,1,1,1002) == 2.0,
            "Recovered timers publish a real completed GPU interval");
        const auto prior_deletes = resumed.deletes;
        check(session.update(resumed,-1,0,1003) == 0 && resumed.deletes == prior_deletes,
            "Stopping without an EGL context discards names without deleting another context's queries");
        check(session.update(resumed,1,1,1004) == 0 && resumed.initializations == 3,
            "Even a reused EGL context handle starts a fresh timer session after stopping");
        resumed.clock += 3000000; session.update(resumed,0,1,1005); resumed.complete();
        check(session.update(resumed,1,1,1006) == 3.0,
            "The new session rejects old measurements and produces a new valid sample");
        session.update(resumed,0,1,1007);
        const auto before_stall = resumed.deletes;
        check(session.update(resumed,1,1,2007) == 0 && resumed.deletes > before_stall,
            "An abandoned pending ring is released after one second without manufacturing headroom");
        check(session.update(resumed,-1,1,2008) == 0,
            "An active-context stop releases the recovered session");
        std::cout << "Frame GPU timing: " << checks << " checks, 0 failures\n";
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
