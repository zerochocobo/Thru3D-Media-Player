// Anime4K's networks on one GL context: each pass of the mpv shaders is one draw into a half-float
// texture, in the shaders' own order. Programs are linked the first time a network is used.
#include "anime4k.h"
#include <android/log.h>
#include <EGL/egl.h>
#include <GLES3/gl32.h>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace anime4k_glsl {
#include "anime4k_glsl.h"
}

namespace anime4k {
namespace {
void log(int priority, const std::string& text) { __android_log_write(priority, "QuestAnime4K", text.c_str()); }

// anime4k_glsl.h's chains, in Generate-Anime4kGlsl.ps1's order: four kinds of four tiers.
enum Kind { RESTORE = 0, RESTORE_SOFT = 1, UPSCALE = 2, UPSCALE_DENOISE = 3 };
constexpr int kTiers = 4;
const anime4k_glsl::Chain& network(Kind kind, int tier) { return anime4k_glsl::chains[kind * kTiers + tier]; }

const char* const kVertex = "#version 300 es\n"
    "out highp vec2 v_uv;\n"
    "void main() { vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));\n"
    "  v_uv = p; gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0); }\n";

struct Target { GLuint texture = 0, framebuffer = 0; int width = 0, height = 0; bool linear = false; };

GLuint compile(GLenum type, const char* source) {
    const GLuint shader = glCreateShader(type);
    glShaderSource(shader, 1, &source, nullptr); glCompileShader(shader);
    GLint ok = 0; glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char text[512] = {}; glGetShaderInfoLog(shader, sizeof(text) - 1, nullptr, text);
        log(ANDROID_LOG_WARN, std::string("shader: ") + text);
        glDeleteShader(shader); return 0;
    }
    return shader;
}

GLuint link(const char* fragment) {
    const GLuint vs = compile(GL_VERTEX_SHADER, kVertex), fs = compile(GL_FRAGMENT_SHADER, fragment);
    if (!vs || !fs) { if (vs) glDeleteShader(vs); if (fs) glDeleteShader(fs); return 0; }
    const GLuint id = glCreateProgram();
    glAttachShader(id, vs); glAttachShader(id, fs); glLinkProgram(id);
    glDeleteShader(vs); glDeleteShader(fs);
    GLint ok = 0; glGetProgramiv(id, GL_LINK_STATUS, &ok);
    if (!ok) { log(ANDROID_LOG_WARN, "program does not link"); glDeleteProgram(id); return 0; }
    return id;
}

bool ensure(Target& target, int width, int height, bool linear) {
    if (target.texture && target.width == width && target.height == height && target.linear == linear) return true;
    if (target.framebuffer) glDeleteFramebuffers(1, &target.framebuffer);
    if (target.texture) glDeleteTextures(1, &target.texture);
    target = Target{};
    glGenTextures(1, &target.texture);
    glBindTexture(GL_TEXTURE_2D, target.texture);
    glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA16F, width, height);
    // The networks' layers read whole texels at fixed offsets; the pictures between them (MAIN) are also
    // read in between texels by the depth-to-space pass, as mpv samples them.
    const GLint filter = linear ? GL_LINEAR : GL_NEAREST;
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, filter); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, filter);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glGenFramebuffers(1, &target.framebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, target.framebuffer);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, target.texture, 0);
    const bool complete = glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
    if (!complete) {
        log(ANDROID_LOG_WARN, "half-float framebuffer incomplete");
        glDeleteFramebuffers(1, &target.framebuffer); glDeleteTextures(1, &target.texture);
        target = Target{};
        return false;
    }
    target.width = width; target.height = height; target.linear = linear;
    return true;
}

void release(Target& target) {
    if (target.framebuffer) glDeleteFramebuffers(1, &target.framebuffer);
    if (target.texture) glDeleteTextures(1, &target.texture);
    target = Target{};
}

// The texture units a pass binds, put back afterwards: Godot's renderer keeps its own bindings there.
constexpr int kUnits = 16;
struct Units {
    GLint active = 0, textures[kUnits] = {}, samplers[kUnits] = {};
    int used = 0;
    explicit Units(int count) : used(count) {
        glGetIntegerv(GL_ACTIVE_TEXTURE, &active);
        for (int i = 0; i < used; ++i) {
            glActiveTexture(GL_TEXTURE0 + i);
            glGetIntegerv(GL_TEXTURE_BINDING_2D, &textures[i]); glGetIntegerv(GL_SAMPLER_BINDING, &samplers[i]);
        }
    }
    ~Units() {
        for (int i = 0; i < used; ++i) {
            glActiveTexture(GL_TEXTURE0 + i);
            glBindTexture(GL_TEXTURE_2D, static_cast<GLuint>(textures[i])); glBindSampler(i, static_cast<GLuint>(samplers[i]));
        }
        glActiveTexture(static_cast<GLenum>(active));
    }
};
/** A network's programs, one per pass, each with its samplers on the units named by its binds; empty
 * when one does not compile or link. */
std::vector<GLuint> link_network(int index) {
    const anime4k_glsl::Chain& net = anime4k_glsl::chains[index];
    std::vector<GLuint> programs;
    for (int pass = 0; pass < net.count; ++pass) {
        const GLuint id = link(net.passes[pass].fragment);
        if (!id) {
            for (GLuint made : programs) glDeleteProgram(made);
            log(ANDROID_LOG_WARN, std::string("network refused: ") + net.name);
            return {};
        }
        glUseProgram(id);
        for (int bind = 0; bind < net.passes[pass].bind_count; ++bind)
            glUniform1i(glGetUniformLocation(id, net.passes[pass].binds[bind]), bind);
        programs.push_back(id);
    }
    glUseProgram(0);
    return programs;
}

// Links networks away from the drawing thread: their programs take long to link (Quest 3: about 0.3 s
// for an M network, 1.1 s for a VL one), which on Godot's thread would freeze the headset's view. A thread
// with its own EGL context in the drawing context's share group links them; the picture is drawn without
// the networks until they are ready. Where the context cannot be made, the drawing thread links them.
struct Compiler {
    std::thread thread;
    std::mutex mutex;
    std::condition_variable wake;
    std::deque<int> queue; // networks asked for, not yet taken
    std::vector<std::pair<int, std::vector<GLuint>>> done; // linked (or refused: empty), not yet handed over
    bool stop = false, failed = false;
    EGLDisplay display = EGL_NO_DISPLAY;
    EGLContext share = EGL_NO_CONTEXT;
};

void compile_loop(Compiler* compiler) {
    EGLSurface surface = EGL_NO_SURFACE;
    EGLContext context = EGL_NO_CONTEXT;
    const EGLint config_attributes[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_NONE};
    const EGLint surface_attributes[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE};
    const EGLint context_attributes[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
    EGLConfig config{}; EGLint count = 0;
    if (eglBindAPI(EGL_OPENGL_ES_API) && eglChooseConfig(compiler->display, config_attributes, &config, 1, &count) && count == 1) {
        surface = eglCreatePbufferSurface(compiler->display, config, surface_attributes);
        context = eglCreateContext(compiler->display, config, compiler->share, context_attributes);
    }
    if (surface == EGL_NO_SURFACE || context == EGL_NO_CONTEXT || !eglMakeCurrent(compiler->display, surface, surface, context)) {
        log(ANDROID_LOG_WARN, "no shared context for linking: the drawing thread links the networks");
        if (context != EGL_NO_CONTEXT) eglDestroyContext(compiler->display, context);
        if (surface != EGL_NO_SURFACE) eglDestroySurface(compiler->display, surface);
        std::lock_guard<std::mutex> lock(compiler->mutex);
        compiler->failed = true;
        return;
    }
    for (;;) {
        int index = -1;
        {
            std::unique_lock<std::mutex> lock(compiler->mutex);
            compiler->wake.wait(lock, [&] { return compiler->stop || !compiler->queue.empty(); });
            if (compiler->stop) break;
            index = compiler->queue.front();
            compiler->queue.pop_front();
        }
        std::vector<GLuint> programs = link_network(index);
        // Whole before the drawing context uses them.
        glFinish();
        std::lock_guard<std::mutex> lock(compiler->mutex);
        compiler->done.emplace_back(index, std::move(programs));
    }
    eglMakeCurrent(compiler->display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    eglDestroyContext(compiler->display, context);
    eglDestroySurface(compiler->display, surface);
}
} // namespace

struct State {
    // Programs by network (kind * tiers + tier), one per pass; empty until the network is first used.
    std::vector<GLuint> programs[4 * kTiers];
    bool refused[4 * kTiers] = {};
    bool asked[4 * kTiers] = {}; // handed to the compiler
    Compiler* compiler = nullptr;
    bool pending = false; // the last run waited for its networks to link
    Target input;
    // The textures a run draws, by its passes in order: what each pass saves.
    std::vector<Target> targets;
    // The last run's result, for a picture drawn again.
    long long key = -1; Settings settings; int width = 0, height = 0;
    GLuint result = 0; int result_width = 0, result_height = 0;
};

Settings from(const float* values) {
    Settings settings;
    settings.mode = static_cast<int>(values[0] + 0.5f);
    settings.tier = static_cast<int>(values[1] + 0.5f);
    settings.doublings = static_cast<int>(values[2] + 0.5f);
    if (!settings.active()) settings = Settings{};
    return settings;
}

State* create() { return new State(); }

void destroy(State*& state) {
    if (!state) return;
    if (Compiler* compiler = state->compiler) {
        { std::lock_guard<std::mutex> lock(compiler->mutex); compiler->stop = true; }
        compiler->wake.notify_all();
        if (compiler->thread.joinable()) compiler->thread.join();
        // Programs are shared with this context: what was linked and never handed over goes here.
        for (auto& entry : compiler->done) for (GLuint id : entry.second) glDeleteProgram(id);
        delete compiler;
    }
    for (auto& list : state->programs) for (GLuint id : list) if (id) glDeleteProgram(id);
    release(state->input);
    for (auto& target : state->targets) release(target);
    delete state;
    state = nullptr;
}

GLuint input(State& state, int width, int height, GLuint& framebuffer) {
    if (!ensure(state.input, width, height, true)) return 0;
    state.key = -1; // what the networks last saw is drawn over
    framebuffer = state.input.framebuffer;
    return state.input.texture;
}

GLuint kept(State& state, long long key, const Settings& settings, int width, int height, int& out_width, int& out_height) {
    if (key < 0 || state.key != key || !(state.settings == settings) || state.width != width || state.height != height || !state.result) return 0;
    out_width = state.result_width; out_height = state.result_height;
    return state.result;
}

bool pending(const State& state) { return state.pending; }

void keep(State& state, long long key, const Settings& settings, int width, int height) {
    state.key = key; state.settings = settings; state.width = width; state.height = height;
}

GLuint run(State& state, const Settings& settings, int& out_width, int& out_height) {
    if (!settings.active() || !state.input.texture) return 0;
    state.key = -1;
    // The official v4 modes: A restores then enlarges, B the same with the softer restore, C enlarges and
    // denoises in one; a second enlargement uses the tier below (VL and L then M), as mode A's HQ does.
    std::vector<const anime4k_glsl::Chain*> chain;
    std::vector<int> indices;
    const int lower = settings.tier >= 2 ? 1 : 0;
    const auto add = [&](Kind kind, int tier) { chain.push_back(&network(kind, tier)); indices.push_back(kind * kTiers + tier); };
    if (settings.mode == 1) add(RESTORE, settings.tier);
    if (settings.mode == 2) add(RESTORE_SOFT, settings.tier);
    if (settings.doublings >= 1) add(settings.mode == 3 ? UPSCALE_DENOISE : UPSCALE, settings.tier);
    if (settings.doublings >= 2) add(UPSCALE, lower);
    // What this run needs, linked by the compiler: until all of it is, the caller draws without them.
    state.pending = false;
    if (!state.compiler) {
        state.compiler = new Compiler();
        state.compiler->display = eglGetCurrentDisplay();
        state.compiler->share = eglGetCurrentContext();
        if (state.compiler->display != EGL_NO_DISPLAY && state.compiler->share != EGL_NO_CONTEXT)
            state.compiler->thread = std::thread(compile_loop, state.compiler);
        else state.compiler->failed = true;
    }
    Compiler& compiler = *state.compiler;
    bool linked_here = false;
    {
        std::lock_guard<std::mutex> lock(compiler.mutex);
        for (auto& entry : compiler.done) {
            if (entry.second.empty()) state.refused[entry.first] = true;
            else state.programs[entry.first] = std::move(entry.second);
        }
        compiler.done.clear();
        linked_here = compiler.failed;
        for (int index : indices) {
            if (state.refused[index]) return 0;
            if (!state.programs[index].empty()) continue;
            if (linked_here) continue;
            if (!state.asked[index]) { compiler.queue.push_back(index); state.asked[index] = true; }
            state.pending = true;
        }
    }
    if (state.pending) { compiler.wake.notify_one(); return 0; }
    for (int index : indices) {
        if (!state.programs[index].empty()) continue;
        state.programs[index] = link_network(index);
        if (state.programs[index].empty()) { state.refused[index] = true; return 0; }
    }
    int max_binds = 0, passes = 0;
    for (const auto* net : chain) {
        passes += net->count;
        for (int pass = 0; pass < net->count; ++pass) if (net->passes[pass].bind_count > max_binds) max_binds = net->passes[pass].bind_count;
    }
    if (static_cast<int>(state.targets.size()) < passes) state.targets.resize(passes);
    GLint program = 0, array = 0;
    glGetIntegerv(GL_CURRENT_PROGRAM, &program); glGetIntegerv(GL_VERTEX_ARRAY_BINDING, &array);
    const GLboolean blend = glIsEnabled(GL_BLEND), scissor = glIsEnabled(GL_SCISSOR_TEST), depth = glIsEnabled(GL_DEPTH_TEST);
    glDisable(GL_BLEND); glDisable(GL_SCISSOR_TEST); glDisable(GL_DEPTH_TEST);
    glBindVertexArray(0);
    bool ok = true;
    GLuint main = state.input.texture;
    int main_width = state.input.width, main_height = state.input.height;
    {
        Units units(max_binds);
        int slot = 0;
        for (size_t step = 0; step < chain.size() && ok; ++step) {
            const anime4k_glsl::Chain& net = *chain[step];
            std::map<std::string, GLuint> saved;
            for (int pass = 0; pass < net.count && ok; ++pass, ++slot) {
                const anime4k_glsl::Pass& p = net.passes[pass];
                const bool is_main = std::strcmp(p.save, "MAIN") == 0;
                const int width = p.doubled ? main_width * 2 : main_width, height = p.doubled ? main_height * 2 : main_height;
                Target& target = state.targets[slot];
                if (!ensure(target, width, height, is_main)) { ok = false; break; }
                glBindFramebuffer(GL_FRAMEBUFFER, target.framebuffer);
                glViewport(0, 0, width, height);
                const GLenum discard = GL_COLOR_ATTACHMENT0;
                glInvalidateFramebuffer(GL_FRAMEBUFFER, 1, &discard);
                glUseProgram(state.programs[indices[step]][pass]);
                for (int bind = 0; bind < p.bind_count; ++bind) {
                    GLuint texture = main;
                    if (std::strcmp(p.binds[bind], "MAIN") != 0) {
                        const auto found = saved.find(p.binds[bind]);
                        if (found == saved.end()) { ok = false; break; }
                        texture = found->second;
                    }
                    glActiveTexture(GL_TEXTURE0 + bind); glBindTexture(GL_TEXTURE_2D, texture); glBindSampler(bind, 0);
                }
                if (!ok) break;
                glDrawArrays(GL_TRIANGLES, 0, 3);
                if (is_main) { main = target.texture; main_width = width; main_height = height; }
                else saved[p.save] = target.texture;
            }
        }
    }
    glUseProgram(static_cast<GLuint>(program)); glBindVertexArray(static_cast<GLuint>(array));
    if (blend) glEnable(GL_BLEND);
    if (scissor) glEnable(GL_SCISSOR_TEST);
    if (depth) glEnable(GL_DEPTH_TEST);
    if (!ok || main == state.input.texture) return 0;
    state.result = main; state.result_width = main_width; state.result_height = main_height;
    out_width = main_width; out_height = main_height;
    return main;
}
}
