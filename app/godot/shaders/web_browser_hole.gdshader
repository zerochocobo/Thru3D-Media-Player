shader_type spatial;
// The opaque Android Surface is submitted by OpenXR. Preserve depth-tested pointers in front.
render_mode unshaded, blend_mul, cull_disabled, depth_draw_never, fog_disabled, shadows_disabled;
void fragment() {
	ALBEDO = vec3(0.0);
	ALPHA = 0.0;
}
