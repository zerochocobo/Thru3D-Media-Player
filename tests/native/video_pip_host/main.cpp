#include VIDEO_LAYER_SOURCE
#include <iostream>
#include <limits>

bool thru3d_color_scale_bias_enabled() { return false; }

namespace fixture {
int checks = 0;
void check(bool ok, const char* message) {
    ++checks;
    if (!ok) throw std::runtime_error(message);
}
struct Floats {
    jsize length;
    std::array<float, 84> values{};
    jfloatArray handle() { return reinterpret_cast<jfloatArray>(this); }
};
jsize JNICALL length(JNIEnv*, jarray value) { return reinterpret_cast<Floats*>(value)->length; }
void JNICALL read(JNIEnv*, jfloatArray value, jsize start, jsize count, jfloat* target) {
    const auto& array = *reinterpret_cast<Floats*>(value);
    check(start >= 0 && count >= 0 && start + count <= array.length, "JNI request exceeds supplied array");
    std::copy_n(array.values.data() + start, count, target);
}
constexpr GLenum capabilities[] = {GL_BLEND, GL_SCISSOR_TEST, GL_DEPTH_TEST, GL_CULL_FACE, GL_STENCIL_TEST, GL_DITHER};
struct Snapshot {
    std::array<GLint, 16> integers{};
    std::array<GLboolean, 10> flags{};
    bool operator==(const Snapshot& other) const { return integers == other.integers && flags == other.flags; }
};
Snapshot snapshot() {
    Snapshot result;
    auto& v = result.integers;
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &v[0]);
    glGetIntegerv(GL_CURRENT_PROGRAM, &v[1]);
    glGetIntegerv(GL_VERTEX_ARRAY_BINDING, &v[2]);
    glGetIntegerv(GL_ACTIVE_TEXTURE, &v[3]);
    glGetIntegerv(GL_VIEWPORT, &v[4]);
    for (int i = 0; i < 3; ++i) {
        glActiveTexture(GL_TEXTURE0 + i);
        glGetIntegerv(GL_TEXTURE_BINDING_2D, &v[8 + i]);
        glGetIntegerv(GL_SAMPLER_BINDING, &v[11 + i]);
    }
    glActiveTexture(v[3]);
    glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &v[14]);
    v[15] = DrawState::srgb_control() ? glIsEnabled(DrawState::kFramebufferSrgb) : -1;
    for (size_t i = 0; i < std::size(capabilities); ++i) result.flags[i] = glIsEnabled(capabilities[i]);
    glGetBooleanv(GL_COLOR_WRITEMASK, result.flags.data() + 6);
    return result;
}
GLuint texture(int width, int height, GLenum format = GL_RGBA8, const void* pixels = nullptr) {
    GLuint value = 0;
    glGenTextures(1, &value);
    glBindTexture(GL_TEXTURE_2D, value);
    glTexStorage2D(GL_TEXTURE_2D, 1, format, width, height);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    if (pixels) glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
    return value;
}
}

int main() {
    using namespace fixture;
    try {
        const EGLDisplay display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
        check(eglInitialize(display, nullptr, nullptr), "EGL initialization failed");
        const EGLint attributes[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
            EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE};
        EGLConfig config{};
        EGLint count = 0;
        check(eglChooseConfig(display, attributes, &config, 1, &count) && count, "GLES3 config unavailable");
        const EGLint context_attributes[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
        const EGLContext context = eglCreateContext(display, config, EGL_NO_CONTEXT, context_attributes);
        const EGLint pbuffer_attributes[] = {EGL_WIDTH, 32, EGL_HEIGHT, 32, EGL_NONE};
        const EGLSurface surface = eglCreatePbufferSurface(display, config, pbuffer_attributes);
        check(context != EGL_NO_CONTEXT && surface != EGL_NO_SURFACE && eglMakeCurrent(display, surface, surface, context), "GLES context failed");
        std::cout << "GLES renderer: " << glGetString(GL_RENDERER) << '\n';

        JNINativeInterface table{};
        table.GetArrayLength = length;
        table.GetFloatArrayRegion = read;
        JNIEnv env{&table};
        Floats common{84}, windows{48};
        auto& values = common.values;
        values[7] = 180; values[8] = 128; values[9] = 64;
        values[10] = values[11] = values[19] = values[24] = values[25] = 1;
        values[20] = values[21] = 32; values[27] = 128; values[28] = 64;
        for (int i = 31; i <= 36; ++i) values[i] = 1;
        values[40] = values[41] = 1;
        for (int i = 0; i < 3; ++i) {
            float* w = windows.values.data() + i * 16;
            w[0] = w[1] = 0.5f; w[2] = w[3] = 1.0f / 3;
            w[6] = -1; w[7] = w[11] = 1; w[13] = w[14] = 0.577f;
        }
        std::vector<uint8_t> pixels(128 * 64 * 4);
        for (size_t i = 0; i < pixels.size(); i += 4) {
            pixels[i] = 64; pixels[i + 1] = 128; pixels[i + 2] = 192; pixels[i + 3] = 255;
        }
        const GLuint source = texture(128, 64, GL_RGBA8, pixels.data());
        auto& main = state.pictures[0];
        main.width = 128; main.height = 64; main.acquired = texture(128, 64, GL_SRGB8_ALPHA8);
        auto& crops = state.pictures[3];
        crops.width = 68; crops.height = 204; crops.acquired = texture(68, 204, GL_SRGB8_ALPHA8);

        GLuint framebuffer = 0, vao = 0, samplers[3]{};
        glGenFramebuffers(1, &framebuffer); glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
        const GLuint framebuffer_texture = texture(64, 64);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, framebuffer_texture, 0);
        glGenVertexArrays(1, &vao); glBindVertexArray(vao);
        const GLuint vs = compile(GL_VERTEX_SHADER, "#version 300 es\nvoid main(){gl_Position=vec4(0,0,0,1);}");
        const GLuint fs = compile(GL_FRAGMENT_SHADER, "#version 300 es\nprecision highp float;out vec4 c;void main(){c=vec4(1);}");
        const GLuint program = glCreateProgram();
        glAttachShader(program, vs); glAttachShader(program, fs); glLinkProgram(program); glUseProgram(program);
        glGenSamplers(3, samplers);
        for (int i = 0; i < 3; ++i) {
            glActiveTexture(GL_TEXTURE0 + i); texture(4, 4); glBindSampler(i, samplers[i]);
        }
        glActiveTexture(GL_TEXTURE5);
        glViewport(7, 9, 23, 29);
        for (size_t i = 0; i < std::size(capabilities); ++i) DrawState::set(capabilities[i], i % 2 == 0);
        glColorMask(GL_TRUE, GL_FALSE, GL_TRUE, GL_FALSE);
        if (DrawState::srgb_control()) glDisable(DrawState::kFramebufferSrgb);
        check(glGetError() == GL_NO_ERROR, "Fixture GL setup failed");
        const Snapshot before = snapshot();
        auto draw = [&](int active, int eyes, bool expected = true) {
            const bool ok = Java_org_vrpassthroughplayer_plugin_VideoLayerNative_renderPip(&env, nullptr,
                active == 8 ? 0 : 3, source, JNI_FALSE, 0, active, eyes, common.handle(), windows.handle());
            check(ok == expected, "Native draw returned unexpected result");
            check(snapshot() == before, "Native PiP corrupted the caller's GL state");
            check(glGetError() == GL_NO_ERROR, "Native PiP left a GL error");
        };
        // Zero text data matches the disabled feature in the affected Release.
        // Nonzero tail data detects truncation and accidental reuse as GL handles.
        for (int iteration = 0; iteration < 4; ++iteration) {
            for (int geometry : {1, 3}) for (int eyes : {1, 2}) {
                values[0] = static_cast<float>(geometry); values[1] = eyes == 2;
                for (int i = 44; i < 84; ++i) values[i] = iteration % 2 ? (i - 43) / 100.0f : 0;
                draw(8, eyes);
                draw(8, eyes); // unchanged timing key, including all extended parameters
                for (int active : {1, 3, 7}) draw(active, 1);
            }
        }
        common.length = 83; draw(8, 2, false); common.length = 84;
        windows.length = 47; draw(8, 2, false); windows.length = 48;
        values[83] = std::numeric_limits<float>::quiet_NaN(); draw(8, 2, false); values[83] = 0;
        // The main and crop targets must contain video after the real draw.
        for (const auto* target : {&main, &crops}) {
            glBindFramebuffer(GL_READ_FRAMEBUFFER, framebuffer);
            glFramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, target->acquired, 0);
            std::array<uint8_t, 4> pixel{};
            glReadPixels(target->width / 2, target == &main ? 32 : 34, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel.data());
            check(pixel[0] > 20 && pixel[1] > 40 && pixel[2] > 80 && pixel[3] == 255, "PiP target lost its video pixels");
        }
        check(glGetError() == GL_NO_ERROR, "PiP pixel readback failed");
        eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        eglDestroySurface(display, surface); eglDestroyContext(display, context); eglTerminate(display);
        std::cout << "Native PiP GL-state regression: " << checks << " checks, 0 failures\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "Native PiP GL-state regression failed: " << error.what() << '\n';
        return 1;
    }
}
