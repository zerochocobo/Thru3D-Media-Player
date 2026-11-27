shader_type spatial;
render_mode unshaded, cull_disabled, blend_add, depth_draw_never, shadows_disabled;
uniform float room_light = 1.0;

void vertex() {
	float width = length(MODEL_MATRIX[0].xyz);
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0]*width, INV_VIEW_MATRIX[1]*width,
		INV_VIEW_MATRIX[2]*width, MODEL_MATRIX[3]);
}

void fragment() {
	float r = length(UV - .5) * 2.;
	ALBEDO = COLOR.rgb;
	ALBEDO *= room_light;
	ALPHA = pow(max(0., 1.-r*r), 3.) * .64;
}
