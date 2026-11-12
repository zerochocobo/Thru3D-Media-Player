// Reads a Unity scene AssetBundle (UnityFS) and writes a neutral scene container that the
// Godot side loads with bulk array reads. No engine dependency: builds as a desktop tool
// and as part of the Android player plugin.
#pragma once
#include <cstddef>

#ifdef __cplusplus
extern "C" {
#endif

// Returns 0 on success. On failure writes a short reason into `error` (UTF-8, NUL terminated).
// Paths are UTF-8. `max_texture` drops mip levels above that edge length (0 keeps everything);
// `max_sky_texture` is the same limit for the sky panorama.
int thru3d_unity_scene_unpack(const char* bundle_path, const char* output_path, int max_texture,
                              int max_sky_texture, char* error, size_t error_size);

#ifdef __cplusplus
}
#endif
