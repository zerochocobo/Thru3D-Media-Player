shader_type spatial;
render_mode unshaded, cull_back, depth_draw_opaque;

uniform sampler2D surface_texture : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform float cinema_light_mix : hint_range(0.0, 1.0) = 1.0;
// Film colour per screen strip; the strips' baked chair light is CUSTOM0.xyz.
uniform vec3 film_left = vec3(0.0);
uniform vec3 film_center = vec3(0.0);
uniform vec3 film_right = vec3(0.0);
// Debug A/B only: 1 skips the sRGB conversions, 2 draws flat colour without texture reads.
uniform int debug_probe = 0;
varying vec3 baked_light;

vec3 decode_srgb(vec3 v) {
	return mix(v / 12.92, pow((v + vec3(0.055)) / 1.055, vec3(2.4)), step(vec3(0.04045), v));
}
vec3 encode_srgb(vec3 v) {
	v = max(v, vec3(0.0));
	return mix(v * 12.92, 1.055 * pow(v, vec3(1.0 / 2.4)) - vec3(0.055), step(vec3(0.0031308), v));
}

void vertex() {
	// Square-root encoding keeps useful precision in dark vertex lighting.
	vec3 on = COLOR.rgb;
	vec3 off = vec3(UV2, COLOR.a);
	vec3 zones = CUSTOM0.xyz * CUSTOM0.xyz;
	vec3 film = zones.x * film_left + zones.y * film_center + zones.z * film_right;
	baked_light = (mix(off * off, on * on, cinema_light_mix) + film) * 8.0;
}

void fragment() {
	if (debug_probe == 2) {
		ALBEDO = vec3(0.2);
	} else {
		bool srgb = OUTPUT_IS_SRGB && debug_probe == 0;
		vec3 surface = texture(surface_texture, UV).rgb;
		if (srgb) surface = decode_srgb(surface);
		vec3 color = surface * baked_light;
		ALBEDO = srgb ? encode_srgb(color) : color;
	}
}
