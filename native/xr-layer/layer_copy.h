// What frame interpolation (frame_interp.cpp) uses of the layer copy (layer_copy.cpp). Copy thread only,
// with its EGL context current.
#pragma once
#include <jni.h>
#include <android/hardware_buffer.h>
#include <GLES3/gl3.h>

namespace layer_copy {
/** The buffer as an external texture; each buffer is wrapped once and kept. 0 when that fails. */
GLuint texture(AHardwareBuffer* buffer);
/** Stops keeping [buffer]'s texture, before its owner releases the buffer. */
void forget(AHardwareBuffer* buffer);
/** A linked program, or 0 (the reason is logged). */
GLuint linked(const char* vertex, const char* fragment);
/** VideoLayerNative.blitBuffer's draw of one buffer over the current EGL surface. */
bool blit(JNIEnv* env, AHardwareBuffer* buffer, jint width, jint height, jint buffer_width, jint buffer_height, jint out_width, jint out_height,
          jboolean flip, jboolean quality, jfloat sharpen, jfloatArray window, jfloatArray grade, jfloat denoise_step, jfloat denoise_tolerance,
          jfloatArray plugin = nullptr, jlong frame = -1);
}

namespace frame_interp {
/** The layer copy's GL objects, before the copy thread's context goes. */
void release();

// 2D->3D's stereo pairs (both eyes side by side in one GL_RGBA8 texture), on Godot's render thread with
// its context current; the GL state touched is put back.
/** Keeps a copy of the pair [texture] under [id] (the four pairs pushed last are kept) and estimates the
 * motion from the pair kept as [before_id] (-1: none) to it. False when this GL cannot interpolate. */
bool pair_push(GLuint texture, int width, int height, jlong id, jlong before_id);
/** pair_push in parts, for a caller that draws the pair into its copy itself: the texture kept under
 * [id] (0: this GL cannot interpolate), then the motion once it is drawn; pair_forget drops a copy
 * that could not be drawn. */
GLuint pair_slot(int width, int height, jlong id);
bool pair_estimate(jlong id, jlong before_id);
void pair_forget(jlong id);
/** pair_picture drawn straight into [image], an sRGB texture of the pairs' size (a picture layer's). */
bool pair_show(GLuint image, jlong before_id, jlong after_id, float phase);
/** A texture of the pairs' size holding the picture [phase] (0..1) of the way from one kept pair to
 * another: a pair's own copy at 0 or 1 or where the motion is missing. 0 when neither pair is kept. */
GLuint pair_picture(jlong before_id, jlong after_id, float phase);
/** Frees the copies and everything made for them. */
void pair_release();
}
