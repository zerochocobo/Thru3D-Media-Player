shader_type spatial;
// Clears the eye buffer to transparent black where the compositor video layer shows through.
// Reverse subtract of opaque white gives zero colour and alpha over any background, opaque or not.
// Drawn first among transparent objects without writing depth, so menus in front still cover it.
render_mode unshaded, blend_sub, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

// Surface UV rectangle to clear; the rest of the mesh stays (a photo's soft edge drawn beside it).
uniform vec4 keep_rect = vec4(0.0, 0.0, 1.0, 1.0);
#include "res://shaders/video_coordinates.gdshaderinc"

void vertex() {
	eye_index = int(VIEW_INDEX);
	media_direction = VERTEX;
}

void fragment() {
	if (any(lessThan(UV, keep_rect.xy)) || any(greaterThan(UV, keep_rect.xy + keep_rect.zw))) { discard; }
	// Uniform branch: the spherical mapping runs only while a stereo alignment offset crops the
	// edges. VR180/360 holes cover most of each eye, and the trigonometry per pixel cost frame
	// rate on XR2 Gen1 headsets that scales with the display quality setting.
	if (stereo_sbs && viewing_eye == 0 && any(notEqual(stereo_offset, vec2(0.0)))) {
		if (outside_alignment(aligned_eye_uv(eye_uv(UV, media_direction)))) { discard; }
	}
	ALBEDO = vec3(1.0);
	ALPHA = 1.0;
}
