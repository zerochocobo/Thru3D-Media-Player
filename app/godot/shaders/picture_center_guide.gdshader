shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform bool cross_shape = false;
uniform float ink_alpha = 0.72;
uniform float opacity = 0.0;
uniform float shape_scale = 1.0;
uniform vec3 head_origin = vec3(0.0);

void vertex() {
	// Reuse the menu_zero_parallax direction projection. Subtract the shared
	// head origin before VIEW_MATRIX rotation so eye translation is removed
	// even when it lives in VIEW_MATRIX instead of Godot's multiview projection.
	// Keep each eye's rotation/FOV; identical pixel coordinates are not correct
	// on asymmetric or canted displays.
	vec3 direction = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz - head_origin;
	POSITION = PROJECTION_MATRIX * vec4(mat3(VIEW_MATRIX) * direction, 0.0);
	POSITION.z = 0.0;
}

float arm(vec2 p) {
	return length(p - vec2(clamp(p.x, 0.20, 0.59), 0.0)) - 0.028;
}

void fragment() {
	vec2 p = (UV - 0.5) * 2.0 / shape_scale;
	float distance_to_ink = abs(length(p) - 0.62) - 0.028;
	if (cross_shape) {
		vec2 q = abs(p);
		distance_to_ink = min(arm(q), arm(q.yx));
	}
	float aa = max(fwidth(distance_to_ink), 0.002);
	float ink = 1.0 - smoothstep(-aa * 0.5, aa * 0.5, distance_to_ink);
	float rim = 1.0 - smoothstep(-aa * 0.5, aa * 0.5, distance_to_ink - 0.034);
	float ink_coverage = ink * ink_alpha;
	float rim_coverage = rim * 0.42 * (1.0 - ink_coverage);
	float coverage = ink_coverage + rim_coverage;
	ALBEDO = (vec3(0.93, 0.96, 0.98) * ink_coverage + vec3(0.025, 0.035, 0.03) * rim_coverage) / max(coverage, 0.0001);
	ALPHA = coverage * opacity;
}
