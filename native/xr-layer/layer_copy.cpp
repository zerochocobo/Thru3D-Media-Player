// Alpha plan B, GPU copy prototype: the decoder writes into an ImageReader whose buffers are reused, and
// each frame is drawn into the compositor layer's surface on a copy thread with its own EGL context. Both
// buffer sets stay fixed (the ImageWriter hand-off made the runtime keep a new buffer per frame).
#include <jni.h>
#include <android/hardware_buffer.h>
#include <android/hardware_buffer_jni.h>
#include <android/log.h>
#include <android/native_window.h>
#include <android/native_window_jni.h>
#define EGL_EGLEXT_PROTOTYPES
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>
#include <list>
#include <string>

namespace {

void log(int priority, const std::string& text) { __android_log_write(priority, "QuestLayerCopy", text.c_str()); }

struct Api {
    PFNEGLGETNATIVECLIENTBUFFERANDROIDPROC client = nullptr;
    PFNEGLCREATEIMAGEKHRPROC create = nullptr;
    PFNEGLDESTROYIMAGEKHRPROC destroy = nullptr;
    PFNGLEGLIMAGETARGETTEXTURE2DOESPROC target = nullptr;
    Api() {
        client = reinterpret_cast<PFNEGLGETNATIVECLIENTBUFFERANDROIDPROC>(eglGetProcAddress("eglGetNativeClientBufferANDROID"));
        create = reinterpret_cast<PFNEGLCREATEIMAGEKHRPROC>(eglGetProcAddress("eglCreateImageKHR"));
        destroy = reinterpret_cast<PFNEGLDESTROYIMAGEKHRPROC>(eglGetProcAddress("eglDestroyImageKHR"));
        target = reinterpret_cast<PFNGLEGLIMAGETARGETTEXTURE2DOESPROC>(eglGetProcAddress("glEGLImageTargetTexture2DOES"));
    }
    bool ready() const { return client && create && destroy && target; }
};
const Api& api() { static const Api value; return value; }

// One wrapped decoder buffer: the reader cycles a few, so each is wrapped once.
struct Wrapped { AHardwareBuffer* buffer; EGLImageKHR image; GLuint texture; };
std::list<Wrapped> cache; // copy thread only, newest first
constexpr size_t kCacheLimit = 16;
GLuint program = 0;
GLint scale_location = -1, flip_location = -1;

void drop(Wrapped& entry) {
    if (entry.texture) glDeleteTextures(1, &entry.texture);
    if (entry.image != EGL_NO_IMAGE_KHR) api().destroy(eglGetCurrentDisplay(), entry.image);
    AHardwareBuffer_release(entry.buffer);
}

GLuint compile(GLenum type, const char* source) {
    const GLuint shader = glCreateShader(type);
    glShaderSource(shader, 1, &source, nullptr); glCompileShader(shader);
    GLint ok = 0; glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char text[512] = {}; glGetShaderInfoLog(shader, sizeof(text) - 1, nullptr, text);
        log(ANDROID_LOG_WARN, std::string("copy shader: ") + text);
        glDeleteShader(shader); return 0;
    }
    return shader;
}

bool ensure_program() {
    if (program) return true;
    static const char* vertex = "#version 300 es\n"
        "uniform bool flip; out vec2 uv;\n"
        "void main() { vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));\n"
        "  uv = vec2(p.x, flip ? 1.0 - p.y : p.y); gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0); }\n";
    // The driver converts the decoder's YUV (8 or 10 bit) to RGB when sampling the external image.
    // highp: uv x 8192 pixels in half floats stepped every 4 pixels across the right half of a
    // side-by-side frame (the right eye's fine detail broke up while the left eye stayed sharp).
    static const char* fragment = "#version 300 es\n"
        "#extension GL_OES_EGL_image_external_essl3 : require\n"
        "precision highp float;\n"
        "uniform samplerExternalOES frame; uniform vec2 scale; in vec2 uv; out vec4 result;\n"
        "void main() { result = vec4(texture(frame, uv * scale).rgb, 1.0); }\n";
    const GLuint vs = compile(GL_VERTEX_SHADER, vertex), fs = compile(GL_FRAGMENT_SHADER, fragment);
    if (!vs || !fs) { if (vs) glDeleteShader(vs); if (fs) glDeleteShader(fs); return false; }
    program = glCreateProgram();
    glAttachShader(program, vs); glAttachShader(program, fs); glLinkProgram(program);
    glDeleteShader(vs); glDeleteShader(fs);
    GLint ok = 0; glGetProgramiv(program, GL_LINK_STATUS, &ok);
    if (!ok) { log(ANDROID_LOG_WARN, "copy program does not link"); glDeleteProgram(program); program = 0; return false; }
    scale_location = glGetUniformLocation(program, "scale");
    flip_location = glGetUniformLocation(program, "flip");
    glUseProgram(program);
    glUniform1i(glGetUniformLocation(program, "frame"), 0);
    return true;
}

GLuint texture_for(AHardwareBuffer* buffer) {
    for (auto it = cache.begin(); it != cache.end(); ++it) {
        if (it->buffer == buffer) { cache.splice(cache.begin(), cache, it); return cache.front().texture; }
    }
    if (cache.size() >= kCacheLimit) { drop(cache.back()); cache.pop_back(); }
    const EGLint attributes[] = {EGL_IMAGE_PRESERVED_KHR, EGL_TRUE, EGL_NONE};
    EGLImageKHR image = api().create(eglGetCurrentDisplay(), EGL_NO_CONTEXT, EGL_NATIVE_BUFFER_ANDROID, api().client(buffer), attributes);
    if (image == EGL_NO_IMAGE_KHR) { log(ANDROID_LOG_WARN, "decoder EGLImage creation failed"); return 0; }
    GLuint texture = 0;
    glGenTextures(1, &texture);
    glBindTexture(GL_TEXTURE_EXTERNAL_OES, texture);
    api().target(GL_TEXTURE_EXTERNAL_OES, static_cast<GLeglImageOES>(image));
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    AHardwareBuffer_acquire(buffer); // the cache entry keeps the buffer alive with its image
    cache.push_front({buffer, image, texture});
    return texture;
}

} // namespace

/** The compositor surface's buffers at the video's own size (RGBA8), before the copy's EGL surface. */
extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_VideoLayerNative_setWindowGeometry(JNIEnv* env, jclass, jobject surface, jint width, jint height) {
    ANativeWindow* window = surface ? ANativeWindow_fromSurface(env, surface) : nullptr;
    if (!window) return JNI_FALSE;
    const int result = ANativeWindow_setBuffersGeometry(window, width, height, AHARDWAREBUFFER_FORMAT_R8G8B8A8_UNORM);
    ANativeWindow_release(window);
    return result == 0 ? JNI_TRUE : JNI_FALSE;
}

/** Draws one decoder buffer over the current EGL surface (the copy thread's context): visible size
 * width x height of a bufferWidth x bufferHeight buffer; flip: the buffer's first row at the top. */
extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_VideoLayerNative_blitBuffer(JNIEnv* env, jclass, jobject hardware_buffer, jint width, jint height,
        jint buffer_width, jint buffer_height, jint out_width, jint out_height, jboolean flip) {
    if (!hardware_buffer || width <= 0 || height <= 0 || buffer_width < width || buffer_height < height ||
        out_width <= 0 || out_height <= 0 || !api().ready()) return JNI_FALSE;
    AHardwareBuffer* buffer = AHardwareBuffer_fromHardwareBuffer(env, hardware_buffer);
    if (!buffer || !ensure_program()) return JNI_FALSE;
    const GLuint texture = texture_for(buffer);
    if (!texture) return JNI_FALSE;
    while (glGetError() != GL_NO_ERROR) {}
    glViewport(0, 0, out_width, out_height);
    glDisable(GL_BLEND); glDisable(GL_DEPTH_TEST); glDisable(GL_SCISSOR_TEST);
    glUseProgram(program);
    glUniform2f(scale_location, static_cast<float>(width) / buffer_width, static_cast<float>(height) / buffer_height);
    glUniform1i(flip_location, flip == JNI_TRUE ? 1 : 0);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_EXTERNAL_OES, texture);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    const GLenum error = glGetError();
    if (error != GL_NO_ERROR) { log(ANDROID_LOG_WARN, "blit GL error " + std::to_string(error)); return JNI_FALSE; }
    return JNI_TRUE;
}

/** The copy thread's GL objects, before its context goes. */
extern "C" JNIEXPORT void JNICALL
Java_org_vrpassthroughplayer_plugin_VideoLayerNative_releaseBlit(JNIEnv*, jclass) {
    for (auto& entry : cache) drop(entry);
    cache.clear();
    if (program) { glDeleteProgram(program); program = 0; }
}
