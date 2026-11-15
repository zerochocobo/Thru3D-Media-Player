shader_type spatial;
// Drawn in the ordered pass after the menu layer holes (input_visuals MODEL_PRIORITY): the cinema
// and beach overlay holes ignore depth and would otherwise cut an opaque controller out. ALPHA 1
// keeps the eye buffer solid there; depth is still written so the pointers test against it.
render_mode unshaded, cull_disabled, depth_draw_always;

uniform vec4 albedo : source_color = vec4(1.0);
uniform sampler2D albedo_texture : source_color, hint_default_white, filter_linear_mipmap;
// Runtime render models keep their flat unshaded look; bundled PICO models get the studio light.
uniform bool studio_light = true;
uniform bool vertex_color = false;

void fragment() {
	// Stable world-space studio lighting keeps the shape legible without adding
	// lights to the video environment. Source textures and depth testing remain.
	vec3 normal = normalize(mat3(INV_VIEW_MATRIX) * NORMAL);
	if (!FRONT_FACING) { normal = -normal; }
	float key = max(dot(normal, normalize(vec3(-0.4, 0.8, 0.6))), 0.0);
	float fill = max(dot(normal, normalize(vec3(0.7, 0.2, -0.5))), 0.0);
	vec3 color = albedo.rgb * texture(albedo_texture, UV).rgb;
	if (vertex_color) { color *= COLOR.rgb; }
	ALBEDO = studio_light ? color * (0.42 + 0.48 * key + 0.10 * fill) : color;
	ALPHA = 1.0;
}
