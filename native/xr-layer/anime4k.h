// Anime4K (bloc97, MIT; third_party/anime4k) as a picture quality plugin: the official v4 modes run on
// one picture with the networks' own GLSL (anime4k_glsl.h, generated from the mpv shaders unchanged).
// Shared by the layer copy (decoder frames, its own context) and the picture layer (software-decoded
// frames, Godot's context): each context keeps its own State and uses it on its own thread.
#pragma once
#include <GLES3/gl3.h>

namespace anime4k {
/** What the plugin does: mode 0 off, 1 A (restore, then enlarge), 2 B (soft restore, then enlarge),
 * 3 C (enlarge while denoising); tier 0 S, 1 M, 2 L, 3 VL; doublings 0..2: how many times the picture
 * is enlarged twice over (the second time by the tier below, as the official modes do). The caller
 * chooses the doublings by the source's size (LayerCopy.anime4kDoublings, mpv_video_display.gd's
 * anime4k_doublings). */
struct Settings {
    int mode = 0, tier = 0, doublings = 0;
    bool active() const { return mode >= 1 && mode <= 3 && tier >= 0 && tier <= 3 && doublings >= 0 && doublings <= 2
        && (mode != 3 || doublings > 0); }
    bool operator==(const Settings& other) const { return mode == other.mode && tier == other.tier && doublings == other.doublings; }
};
/** Settings from three floats (mode, tier, doublings), as the picture values carry them. */
Settings from(const float* values);

struct State;
State* create();
/** Frees the GL objects; [state]'s context must be current. */
void destroy(State*& state);
/** A texture of width x height (RGBA16F, bilinear, clamped) to draw the picture into before run(), with
 * its framebuffer; the same one until the size changes. 0 when this GL cannot render half floats. */
GLuint input(State& state, int width, int height, GLuint& framebuffer);
/** Runs the networks on the input texture (display-encoded values, rows as the picture's). Returns the
 * result (a texture the state owns, RGBA16F, bilinear) and its size, or 0: while a thread sharing this
 * context links the networks (pending), or when a program or texture could not be made. The GL state it
 * changes is put back, except the framebuffer and viewport. */
GLuint run(State& state, const Settings& settings, int& out_width, int& out_height);
/** The last run returned 0 because its networks are still being linked: draw the picture without them
 * and run again with a later frame (or a redraw). */
bool pending(const State& state);
/** The result of the last run for [key] (a frame's identity) and [settings], or 0: a picture drawn
 * again (paused, the head moved) does not run the networks again. */
GLuint kept(State& state, long long key, const Settings& settings, int width, int height, int& out_width, int& out_height);
void keep(State& state, long long key, const Settings& settings, int width, int height);
}
