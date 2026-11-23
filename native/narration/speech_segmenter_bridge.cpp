#include "speech_segmenter.h"
#include <exception>

// quest_listening has no ORT registry of its own (see ort_environment_bridge.cpp):
// it reaches the Silero segmenter through these calls. Errors never cross the C
// boundary; a failed call returns an error code and the caller stops recognition.
namespace {
struct Handle {SpeechSegmenter segmenter;explicit Handle(const char* path):segmenter(path){}};
}
extern "C" __attribute__((visibility("default"))) void* thru3d_segmenter_create(const char* path) {
    try {return new Handle(path);} catch(const std::exception&) {return nullptr;}
}
extern "C" __attribute__((visibility("default"))) void thru3d_segmenter_destroy(void* handle) {
    delete static_cast<Handle*>(handle);
}
/** Feeds 16 kHz mono samples; emit receives each finished segment (start sample, samples). */
extern "C" __attribute__((visibility("default"))) int thru3d_segmenter_accept(void* handle,const float* samples,int64_t count,int finish,
        void (*emit)(void* context,int64_t start,const float* samples,int64_t count),void* context) {
    try {
        for(auto& segment:static_cast<Handle*>(handle)->segmenter.accept(samples,size_t(count),finish!=0))
            emit(context,segment.start,segment.samples.data(),int64_t(segment.samples.size()));
        return 0;
    } catch(const std::exception&) {return -1;}
}
extern "C" __attribute__((visibility("default"))) int64_t thru3d_segmenter_open_start(void* handle) {
    return static_cast<Handle*>(handle)->segmenter.openStart();
}
