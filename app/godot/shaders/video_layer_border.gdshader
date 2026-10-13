shader_type spatial;
// Cropped alignment edges remain black, just as on the shader-video path.
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix, shadows_disabled, fog_disabled;
#include "res://shaders/video_coordinates.gdshaderinc"
void vertex() {
	eye_index = int(VIEW_INDEX);
	media_direction = VERTEX;
}
void fragment() {
	if (!outside_alignment(aligned_eye_uv(eye_uv(UV, media_direction)))) { discard; }
	ALBEDO = vec3(0.0);
	ALPHA = 1.0;
}
