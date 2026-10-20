// Compile the actual patched MNN initialization blocks against a rejecting driver.
// This verifies control flow and ownership; it is not a hardware compatibility test.
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <memory>
#include <string>
#include <type_traits>
#include <vector>

using cl_int = int;
using cl_context_properties = intptr_t;
using cl_queue_properties = intptr_t;
constexpr int CL_SUCCESS = 0, CL_DEVICE_EXTENSIONS = 1, CL_PLATFORM_EXTENSIONS = 2;
constexpr int CL_DEVICE_RECORDABLE_QUEUE_MAX_SIZE = 3, CL_QUEUE_PROFILING_ENABLE = 4;
constexpr int CL_QUEUE_RECORDABLE_QCOM = 8, CL_CONTEXT_PERF_HINT_QCOM = 9;
constexpr int CL_PERF_HINT_HIGH_QCOM = 10, CL_CONTEXT_PRIORITY_HINT_QCOM = 11;
constexpr int CL_PRIORITY_HINT_LOW_QCOM = 12, CL_QUEUE_PRIORITY_KHR = 13;
constexpr int CL_QUEUE_PRIORITY_LOW_KHR = 14;
constexpr int ADRENO = 0, MALI = 1, OTHER = 2;
#define MNN_USE_LIB_WRAPPER
#define MNN_ERROR(...) std::printf(__VA_ARGS__)
#define MNN_CHECK_CL_SUCCESS(error, stage) ((void)0)

struct Driver {
    bool rejectContextHints = false, rejectContext = false;
    bool rejectPriority = false, rejectQueue = false, rejectRecording = false;
    bool missingProperties = false, recording = false;
    unsigned recordLimit = 8;
    int hintedContexts = 0, plainContexts = 0, priorityQueues = 0, plainQueues = 0, recordQueues = 0;
} driver;

namespace cl {
struct Device {
    int get() const { return 1; }
    template<int Name> typename std::conditional<Name == CL_DEVICE_EXTENSIONS, std::string, unsigned>::type getInfo() const {
        if constexpr (Name == CL_DEVICE_EXTENSIONS) return driver.recording ? "cl_qcom_recordable_queues" : "";
        else return driver.recordLimit;
    }
};
struct Platform {
    std::string extensions;
    template<int> std::string getInfo() const { return extensions; }
    int operator()() const { return 1; }
};
struct Context {
    int handle;
    Context(const std::vector<Device>&, const cl_context_properties* props, void*, void*, cl_int* err) {
        if (props) ++driver.hintedContexts; else ++driver.plainContexts;
        *err = (driver.rejectContext || (props && driver.rejectContextHints)) ? -64 : CL_SUCCESS;
        handle = *err == CL_SUCCESS ? 1 : 0;
    }
    int get() const { return handle; }
};
struct CommandQueue {
    int handle;
    explicit CommandQueue(int value) : handle(value) {}
    CommandQueue(const Context&, const Device&, int properties, cl_int* err) {
        if (properties == CL_QUEUE_RECORDABLE_QCOM) {
            ++driver.recordQueues; *err = driver.rejectRecording ? -35 : CL_SUCCESS;
        } else {
            if (properties != CL_QUEUE_PROFILING_ENABLE) ++driver.plainQueues;
            *err = driver.rejectQueue ? -36 : CL_SUCCESS;
        }
        handle = *err == CL_SUCCESS ? 1 : 0;
    }
};
}
int clCreateCommandQueueWithProperties(int, int, cl_queue_properties*, cl_int* err) {
    ++driver.priorityQueues;
    *err = driver.rejectPriority ? -35 : CL_SUCCESS;
    return *err == CL_SUCCESS ? 1 : 0;
}
struct Symbols {
    bool isPropError() const { return driver.missingProperties; }
    bool isQcomError() const { return false; }
    bool getFuncAddress(int, const char*) const { return false; }
};
struct OpenCLSymbolsOperator {
    static Symbols* getOpenclSymbolsPtr() { static Symbols symbols; return &symbols; }
};
std::shared_ptr<cl::Context> globalContext;
std::shared_ptr<cl::Context> getGlobalContext() { return globalContext; }
void setGlobalContext(std::shared_ptr<cl::Context> value) { globalContext = value; }
bool getDeviceSupportsExtension(const cl::Device&, const char* extension) {
    return driver.recording && std::string(extension) == "cl_qcom_recordable_queues";
}
#include "opencl_initialization_diagnostics.inc"

struct Runtime {
    int mGpuType = ADRENO;
    bool mIsDeviceSupportedLowPower = false, mIsSupportAHD = false, mIsCreateError = false;
    bool mSupportRecordQueue = false;
    unsigned mUseRecordableQueueSize = 0;
    std::shared_ptr<cl::Device> mFirstGPUDevicePtr = std::make_shared<cl::Device>();
    std::shared_ptr<cl::Context> mContext;
    std::shared_ptr<cl::CommandQueue> mCommandQueuePtr, mCommandQueueTuning, mRecordableQueuePtr;
    cl::CommandQueue* mCurrentCommandQueue = nullptr;
    void initialize(bool priority, int platformId = 0) {
        vrppClInitializationError.clear();
        cl_int res = CL_SUCCESS;
        const int properties = 0;
        std::vector<cl::Platform> platforms = {{""}, {""}};
        platforms[platformId].extensions = priority ? "cl_khr_priority_hints" : "";
        void* contextPtr = nullptr;
        struct { unsigned encorderNumForCommit = 4; } hint;
        // Generated from patch_opencl_initialization() applied to pristine MNN 3.6.1.
        // Upstream's external-context deleter intentionally ignores its named pointer.
#ifdef _MSC_VER
#pragma warning(push)
#pragma warning(disable: 4100)
#else
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-parameter"
#endif
#include "opencl_initialization_context_queue.inc"
#include "opencl_initialization_recording.inc"
#ifdef _MSC_VER
#pragma warning(pop)
#else
#pragma GCC diagnostic pop
#endif
    }
};

int checks = 0, failures = 0;
void check(bool ok, const char* name) {
    ++checks;
    if (!ok) { ++failures; std::printf("FAIL: %s\n", name); }
}
void reset() { driver = Driver{}; globalContext.reset(); }
bool ready(const Runtime& runtime) {
    return !runtime.mIsCreateError && runtime.mContext && runtime.mContext->get() &&
        runtime.mCommandQueuePtr && runtime.mCommandQueuePtr->handle;
}
int main() {
    reset(); Runtime base; base.initialize(false);
    check(ready(base) && driver.hintedContexts == 1 && driver.plainContexts == 0, "working QCOM context unchanged");
    check(driver.priorityQueues == 0 && driver.plainQueues == 1, "normal GPU queue remains in order");

    reset(); driver.rejectContextHints = true; Runtime context; context.initialize(false);
    check(ready(context) && driver.hintedContexts == 1 && driver.plainContexts == 1, "rejected context hints retry the GPU");
    check(globalContext == context.mContext && !context.mIsDeviceSupportedLowPower, "only successful fallback context is cached");
    check(vrppClInitializationError.empty(), "successful retry does not leave a fatal diagnostic");

    reset(); driver.rejectContext = true; Runtime noContext; noContext.initialize(false);
    check(noContext.mIsCreateError && !globalContext && driver.plainQueues == 0, "real context failure is fatal and never cached");
    check(vrppClInitializationError == "context (-64)", "real context error keeps stage and driver code");

    reset(); Runtime priority; priority.initialize(true, 1);
    check(ready(priority) && driver.priorityQueues == 1 && driver.plainQueues == 0, "selected platform priority path retained");
    reset(); driver.missingProperties = true; Runtime missing; missing.initialize(true);
    check(ready(missing) && driver.priorityQueues == 0 && driver.plainQueues == 1, "missing optional queue symbol uses normal GPU queue");
    reset(); driver.rejectPriority = true; Runtime rejected; rejected.initialize(true);
    check(ready(rejected) && driver.priorityQueues == 1 && driver.plainQueues == 1, "rejected priority queue retries on the GPU");
    check(!rejected.mIsDeviceSupportedLowPower && vrppClInitializationError.empty(), "priority retry clears unsupported hint state");

    reset(); driver.rejectPriority = true; driver.rejectQueue = true; Runtime fatal; fatal.initialize(true);
    check(fatal.mIsCreateError && driver.priorityQueues == 1 && driver.plainQueues == 1, "real queue failure remains fatal");
    check(vrppClInitializationError == "command_queue (-36)", "default queue failure keeps actual error code");

    reset(); driver.recording = true; Runtime record; record.initialize(false);
    check(ready(record) && record.mSupportRecordQueue && record.mUseRecordableQueueSize == 4, "working recordable optimization retained");
    reset(); driver.recording = true; driver.rejectRecording = true; Runtime noRecord; noRecord.initialize(false);
    check(ready(noRecord) && !noRecord.mSupportRecordQueue && !noRecord.mRecordableQueuePtr, "recordable failure preserves normal GPU execution");
    check(noRecord.mUseRecordableQueueSize == 0 && vrppClInitializationError.empty(), "failed recordable optimization clears state");
    reset(); driver.recording = true; driver.recordLimit = 0; Runtime zero; zero.initialize(false);
    check(ready(zero) && !zero.mSupportRecordQueue && driver.recordQueues == 0, "zero recording capacity does not enable a null queue");
    reset(); Runtime other; other.mGpuType = OTHER; other.initialize(false);
    check(ready(other) && driver.hintedContexts == 0 && driver.plainContexts == 1, "non-Adreno GPU stays on its normal path");
    std::printf("MNN OpenCL initialization: %d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}
