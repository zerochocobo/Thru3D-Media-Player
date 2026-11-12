shader_type spatial;
// Soft contact shadow on the real floor below the screen. Alpha blended, depth test
// always, drawn after other transparent surfaces.
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, depth_test_disabled, shadows_disabled, fog_disabled;

uniform vec4 projection_color = vec4(0.0, 0.0, 0.0, 0.18);
uniform float edge_feather : hint_range(0.001, 0.85) = 0.68;
uniform float center_lift : hint_range(0.0, 1.0) = 0.58;

void fragment() {
	float feather = 1.0 - clamp(edge_feather, 0.001, 0.85);
	float inv = 1.0 / (1.0 - feather);
	vec2 q = abs(UV - 0.5) * 2.0;
	float box = max(q.y, q.x);
	float radial = min(length(q), 1.0);
	float lift = 1.0 - center_lift * radial * radial;
	float t = clamp((box - feather) * inv, 0.0, 1.0);
	float edge = 1.0 - (3.0 - 2.0 * t) * t * t;
	ALBEDO = projection_color.rgb;
	ALPHA = clamp(lift * edge, 0.0, 1.0) * projection_color.a;
}
