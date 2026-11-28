shader_type spatial;
// The wands' baked wood and silver (tools/wands/build_wands.py): colour with occlusion in RGB, polish in
// alpha. A fixed key light from above and a glint that follows the eye stand in for real lights, so the
// wand looks lit whichever scene it is in and whichever way the hand turns it.
render_mode unshaded, cull_back, shadows_disabled;
uniform sampler2D atlas : source_color, filter_linear_mipmap, repeat_disable;
uniform vec3 key = vec3(-0.35, 0.85, 0.40);
uniform float light = 1.0;

void fragment() {
	vec4 surface = texture(atlas, UV);
	float polish = surface.a;
	vec3 world_normal = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	vec3 to_key = normalize(key);
	float wrap = max(dot(world_normal, to_key) * 0.6 + 0.4, 0.0);
	float sky = world_normal.y * 0.5 + 0.5;
	vec3 colour = surface.rgb * (0.30 + 0.52 * wrap + 0.08 * sky);
	vec3 key_view = normalize((VIEW_MATRIX * vec4(to_key, 0.0)).xyz);
	vec3 half_way = normalize(key_view + VIEW);
	float shine = pow(max(dot(NORMAL, half_way), 0.0), mix(14.0, 70.0, polish)) * (0.10 + 0.9 * polish);
	float rim = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0) * (0.06 + 0.25 * polish);
	vec3 metal_tint = mix(vec3(1.0, 0.93, 0.82), surface.rgb * 1.6 + 0.2, step(0.99, polish));
	ALBEDO = (colour + (shine + rim) * metal_tint) * light;
}
