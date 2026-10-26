#include "ort_environment.h"

// One registry in quest_narration for all Android ORT consumers. ASR must acquire
// it before Moonshine creates any Env, and release it after every Moonshine model
// and stream is destroyed. Do not instantiate a second registry in another DSO.
extern "C" __attribute__((visibility("default"))) void* thru3d_ort_acquire() {
    return new narration_ort::Lease();
}
extern "C" __attribute__((visibility("default"))) void thru3d_ort_release(void* lease) {
    delete static_cast<narration_ort::Lease*>(lease);
}
