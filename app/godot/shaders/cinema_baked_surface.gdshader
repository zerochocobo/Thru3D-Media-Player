shader_type spatial;
// Cinema architecture: a tiling CC0 scan (UV) times the Blender light bake
// (UV2). Unlit, two texture reads; no runtime lights or shadows.
render_mode unshaded, cull_back;

uniform sampler2D surface_texture : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D light_texture : source_color, filter_linear_mipmap, repeat_disable;
uniform vec3 tint : source_color = vec3(1.0);
// The tint decoded once on the CPU: per-pixel sRGB decoding of a constant cost ALU on every pixel.
uniform vec3 linear_tint = vec3(1.0);
// Must match LIGHT_SCALE in tools/cinema/build_full_lighting.py.
uniform sampler2D light_off_texture : source_color, filter_linear_mipmap, repeat_disable;
uniform float light_scale = 8.0;
uniform float cinema_light_mix : hint_range(0.0, 1.0) = 1.0;
// Screen light baked per zone (R/G/B = left/centre/right strip, same encoding
// as the house maps) and the film's current linear colour for each strip.
uniform sampler2D screen_texture : source_color, hint_default_black, filter_linear_mipmap, repeat_disable;
uniform vec3 film_left = vec3(0.0);
uniform vec3 film_center = vec3(0.0);
uniform vec3 film_right = vec3(0.0);
// Debug A/B only: 1 skips the sRGB conversions, 2 draws flat colour without texture reads.
uniform int debug_probe = 0;

vec3 decode_srgb(vec3 v) {
	return mix(v / 12.92, pow((v + vec3(0.055)) / 1.055, vec3(2.4)), step(vec3(0.04045), v));
}
vec3 encode_srgb(vec3 v) {
	v = max(v, vec3(0.0));
	return mix(v * 12.92, 1.055 * pow(v, vec3(1.0 / 2.4)) - vec3(0.055), step(vec3(0.0031308), v));
}

void fragment() {
	if (debug_probe == 2) {
		ALBEDO = tint;
	} else {
		bool srgb = OUTPUT_IS_SRGB && debug_probe == 0;
		// Uniform branches: read and decode only the bake the current light mix uses (the hall is
		// fully lit or fully dark outside the brief fade), and the screen zones only while a film
		// colour is set. Decoding a skipped zero read would change nothing.
		vec3 on = vec3(0.0);
		vec3 off = vec3(0.0);
		if (cinema_light_mix > 0.0) {
			on = texture(light_texture, UV2).rgb;
			if (srgb) on = decode_srgb(on);
		}
		if (cinema_light_mix < 1.0) {
			off = texture(light_off_texture, UV2).rgb;
			if (srgb) off = decode_srgb(off);
		}
		vec3 film = vec3(0.0);
		if (dot(film_left + film_center + film_right, vec3(1.0)) > 0.0) {
			vec3 zones = texture(screen_texture, UV2).rgb;
			// Compatibility's LDR pipeline operates on sRGB values. Decode before GI math.
			if (srgb) zones = decode_srgb(zones);
			film = zones.r * film_left + zones.g * film_center + zones.b * film_right;
		}
		vec3 surface = texture(surface_texture, UV).rgb;
		if (srgb) surface = decode_srgb(surface);
		vec3 color = surface * (OUTPUT_IS_SRGB ? linear_tint : tint) * (mix(off, on, cinema_light_mix) + film) * light_scale;
		ALBEDO = srgb ? encode_srgb(color) : color;
	}
}
