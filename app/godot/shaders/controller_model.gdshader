shader_type spatial;
render_mode unshaded, cull_disabled;

uniform vec4 albedo : source_color = vec4(1.0);
uniform sampler2D albedo_texture : source_color, hint_default_white, filter_linear_mipmap;

void fragment() {
	// Stable world-space studio lighting keeps the shape legible without adding
	// lights to the video environment. Source textures and depth testing remain.
	vec3 normal = normalize(mat3(INV_VIEW_MATRIX) * NORMAL);
	if (!FRONT_FACING) { normal = -normal; }
	float key = max(dot(normal, normalize(vec3(-0.4, 0.8, 0.6))), 0.0);
	float fill = max(dot(normal, normalize(vec3(0.7, 0.2, -0.5))), 0.0);
	vec3 color = albedo.rgb * texture(albedo_texture, UV).rgb;
	ALBEDO = color * (0.42 + 0.48 * key + 0.10 * fill);
}
