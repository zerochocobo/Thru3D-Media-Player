#pragma once
#include <atomic>
#include <chrono>
#include <memory>
#include <cstdint>
struct VoiceJob {
    std::atomic<bool> cancelled{false};
    std::chrono::steady_clock::time_point deadline=std::chrono::steady_clock::now()+std::chrono::seconds(30);
    static int interrupt(void* p) {
        auto& j=*static_cast<VoiceJob*>(p);
        return j.cancelled.load()||std::chrono::steady_clock::now()>j.deadline;
    }
};
std::shared_ptr<VoiceJob> voice_job(int64_t id);
