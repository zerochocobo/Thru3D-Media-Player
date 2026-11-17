shader_type spatial;
// Soft contact shadow on the real floor below the screen: an elliptical spot, darkest in the
// middle and fading smoothly to nothing at the strip's edge. Drawn after other transparent
// surfaces, without depth test.
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, depth_test_disabled, shadows_disabled, fog_disabled;

uniform vec4 projection_color = vec4(0.0, 0.0, 0.0, 0.15);

void fragment() {
	// r: 0 in the middle of the strip, 1 on the ellipse touching its edges.
	float r = length((UV - 0.5) * 2.0);
	float falloff = pow(clamp(1.0 - r * r, 0.0, 1.0), 2.0);
	ALBEDO = projection_color.rgb;
	ALPHA = falloff * projection_color.a;
}
