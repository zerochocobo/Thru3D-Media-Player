// The effect was first contributed by ghanshyam (github.com/ghanshyamv1) in public PR #9.
// This shader was rewritten for 0.18.1.1.
shader_type spatial;
// Soft shadow on the floor below the screen: darkest in the middle, gone at the quad's sides.
// Drawn after other transparent surfaces, whatever is in front.
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, depth_test_disabled, shadows_disabled, fog_disabled;

uniform float opacity = 0.13;
// The share of each half that stays at full darkness before the fall to the side.
uniform float core = 0.3;

void fragment() {
	vec2 from_centre = abs(UV - 0.5) * 2.0;
	vec2 fall = 1.0 - smoothstep(vec2(core), vec2(1.0), from_centre);
	ALBEDO = vec3(0.0);
	ALPHA = fall.x * fall.y * opacity;
}
