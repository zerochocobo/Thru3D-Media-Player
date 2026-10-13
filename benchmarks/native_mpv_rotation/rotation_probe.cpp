// Compile the production source into this separate diagnostic process. EGL sharing, FFmpeg,
// frame tickets, leases, redraw and seek run without installing an APK. A native-only process
// has no Java VM for MediaCodec; hardware requests must be checked for fallback by the caller.
#include "../../native/mpv/mpv_source.cpp"
#include <fstream>
#include <iostream>

namespace {
struct ProbeEgl {
    EGLDisplay display = EGL_NO_DISPLAY;
    EGLSurface surface = EGL_NO_SURFACE;
    EGLContext context = EGL_NO_CONTEXT;
    ProbeEgl() {
        display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
        require(display != EGL_NO_DISPLAY && eglInitialize(display, nullptr, nullptr), "Probe EGL display");
        require(eglBindAPI(EGL_OPENGL_ES_API), "Probe GLES API");
        const EGLint attrs[] = {EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT_KHR, EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
            EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE};
        EGLConfig config{}; EGLint count = 0;
        require(eglChooseConfig(display, attrs, &config, 1, &count) && count == 1, "Probe EGL config");
        const EGLint ctx[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
        context = eglCreateContext(display, config, EGL_NO_CONTEXT, ctx);
        const EGLint size[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE};
        surface = eglCreatePbufferSurface(display, config, size);
        require(context != EGL_NO_CONTEXT && surface != EGL_NO_SURFACE &&
            eglMakeCurrent(display, surface, surface, context), "Probe owner context");
    }
    ~ProbeEgl() {
        eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if (surface != EGL_NO_SURFACE) eglDestroySurface(display, surface);
        if (context != EGL_NO_CONTEXT) eglDestroyContext(display, context);
        // MediaCodec may also use this display; leave process-wide termination to exit.
    }
};
void probe_jni(JNIEnv* env) { if (env) require(!env->ExceptionCheck(), "Production JNI call raised an exception"); }
std::string capture_probe(JNIEnv* env, jlong handle, const std::string& file) {
    const auto source = find(handle);
    std::string frame;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(25);
    while (frame.empty() && std::chrono::steady_clock::now() < deadline) {
        frame = source->acquire_frame();
        require(!source->render_failed.load() && !source->closing.load(), source->status().c_str());
        if (frame.empty()) std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    require(!frame.empty(), "Timed out waiting for a production source frame");
    uint64_t token = 0;
    {
        std::lock_guard<std::mutex> lock(source->frames_mutex);
        for (auto& slot : source->slots) if (slot.phase == Phase::acquired) {
            token = slot.token;
            if (!slot.image) {
                // Textures are shared between EGL contexts; framebuffer objects are not.
                GLuint read_fbo = 0;
                glGenFramebuffers(1, &read_fbo);
                glBindFramebuffer(GL_READ_FRAMEBUFFER, read_fbo);
                glFramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, slot.color, 0);
                require(glCheckFramebufferStatus(GL_READ_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE, "Probe shared color FBO");
                glBindBuffer(GL_PIXEL_PACK_BUFFER, 0); glPixelStorei(GL_PACK_ALIGNMENT, 1);
                glPixelStorei(GL_PACK_ROW_LENGTH, 0); glPixelStorei(GL_PACK_SKIP_ROWS, 0); glPixelStorei(GL_PACK_SKIP_PIXELS, 0);
                std::vector<unsigned char> pixels(static_cast<size_t>(slot.out_width) * slot.out_height * 4);
                glReadPixels(0, 0, slot.out_width, slot.out_height, GL_RGBA, GL_UNSIGNED_BYTE, pixels.data());
                require(glGetError() == GL_NO_ERROR, "Normalized color readback");
                std::ofstream output(file, std::ios::binary);
                output.write(reinterpret_cast<const char*>(pixels.data()), static_cast<std::streamsize>(pixels.size()));
                require(output.good(), "Probe output write");
                glBindFramebuffer(GL_READ_FRAMEBUFFER, 0);
                glDeleteFramebuffers(1, &read_fbo);
            }
            break;
        }
    }
    require(token > 0, "No acquired source lease");
    require(Java_org_vrpassthroughplayer_plugin_MpvSourceNative_release(env, nullptr, handle, token), "Source lease release");
    probe_jni(env);
    return frame;
}
}

int main(int argc, char** argv) {
    JNIEnv* env = nullptr;
    jlong handle = 0;
    std::unique_ptr<ProbeEgl> egl;
    try {
        require(argc == 6, "Usage: rotation_probe source output_prefix hardware width_cap direct");
        egl = std::make_unique<ProbeEgl>();
        const std::string prefix = argv[2];
        auto candidate = std::make_shared<Source>(argv[1], std::string(argv[3]) == "true", false, 0);
        candidate->max_output_width.store(std::stoi(argv[4]));
        {
            std::lock_guard<std::mutex> lock(registry_mutex);
            handle = ++next_handle; registry.emplace(handle, candidate); candidate->start();
        }
        Java_org_vrpassthroughplayer_plugin_MpvSourceNative_setDirect(env, nullptr, handle, std::string(argv[5]) == "true");
        const auto source = find(handle);
        std::string result = "{\"open\":" + capture_probe(env, handle, prefix + "_open.rgba");
        Java_org_vrpassthroughplayer_plugin_MpvSourceNative_requestFrame(env, nullptr, handle);
        result += ",\"redraw\":" + capture_probe(env, handle, prefix + "_redraw.rgba");
        require(Java_org_vrpassthroughplayer_plugin_MpvSourceNative_seek(env, nullptr, handle, 1500, JNI_TRUE), "Paused exact seek");
        result += ",\"seek\":" + capture_probe(env, handle, prefix + "_seek.rgba");
        Java_org_vrpassthroughplayer_plugin_MpvSourceNative_setPlaying(env, nullptr, handle, JNI_TRUE);
        result += ",\"resume\":" + capture_probe(env, handle, prefix + "_resume.rgba");
        result += ",\"native_status\":" + source->status();
        Java_org_vrpassthroughplayer_plugin_MpvSourceNative_requestClose(env, nullptr, handle);
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(15);
        while (!source->done.load() && std::chrono::steady_clock::now() < deadline)
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
        require(source->done.load(), "Source disposal timed out");
        require(Java_org_vrpassthroughplayer_plugin_MpvSourceNative_close(env, nullptr, handle, JNI_FALSE), "Source close");
        handle = 0;
        probe_jni(env);
        result += ",\"state\":\"passed\",\"disposed\":true}";
        std::cout << result << std::endl;
        return 0;
    } catch (const std::exception& failure) {
        // Keep the owner context alive until its shared worker has stopped, also on failure.
        if (handle > 0) {
            const auto source = find(handle);
            source->closing.store(true); source->abandoned.store(true); source->wake.notify_all();
            if (source->control_thread.joinable()) source->control_thread.join();
            registry.erase(handle);
        }
        std::cout << "{\"state\":\"failed\",\"error\":" << quote(failure.what()) << "}" << std::endl;
        return 1;
    }
}
