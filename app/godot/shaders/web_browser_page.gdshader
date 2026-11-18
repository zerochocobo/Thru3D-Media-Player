shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, fog_disabled, shadows_disabled;

uniform samplerExternalOES page;
uniform mat4 surface_transform = mat4(1.0);
uniform vec4 crop = vec4(0.0, 0.0, 1.0, 1.0);
uniform vec2 page_size = vec2(1.0);
// QIYU factory runtime: white pages come out overexposed (user reports, 2026-11-17/18).
uniform bool decode_srgb = false;
// Browser 3D: a side-by-side pair, left eye on the left; matte keeps the producer's alpha.
uniform bool stereo = false;
uniform bool matte = false;

const int MAX_TAPS = 4;

void fragment() {
	vec2 at = crop.xy + UV * crop.zw;
	if (stereo) at.x = (at.x + (VIEW_INDEX == VIEW_RIGHT ? 1.0 : 0.0)) * 0.5;
	vec2 uv = (surface_transform * vec4(at.x, 1.0 - at.y, 0.0, 1.0)).xy;
	// The OES texture has no mipmaps: one bilinear tap per pixel drops text strokes once a
	// pixel covers more than a texel (1440 eye buffers). Box-filter the pixel's footprint.
	vec2 dx = dFdx(uv), dy = dFdy(uv);
	ivec2 taps = clamp(ivec2(ceil(vec2(length(dx * page_size), length(dy * page_size)))), ivec2(1), ivec2(MAX_TAPS));
	vec4 sum = vec4(0.0);
	for (int j = 0; j < MAX_TAPS; j++) {
		if (j >= taps.y) break;
		for (int i = 0; i < MAX_TAPS; i++) {
			if (i >= taps.x) break;
			vec2 f = (vec2(float(i), float(j)) + 0.5) / vec2(taps) - 0.5;
			sum += texture(page, uv + f.x * dx + f.y * dy);
		}
	}
	// The OES sampler yields SDR encoded RGB. Compatibility's lighting space is sRGB.
	sum /= float(taps.x * taps.y);
	vec3 color = sum.rgb;
	if (decode_srgb) color = mix(color / 12.92, pow((color + 0.055) / 1.055, vec3(2.4)), step(0.04045, color));
	ALBEDO = color;
	ALPHA = matte ? sum.a : 1.0;
}
