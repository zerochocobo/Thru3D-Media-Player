// Same display transform for decoder OES and inferred/packed color textures.
// Operates on decoded display RGB, after sampling; masks and model input are untouched.
uniform bool grade_enabled = false;
uniform vec3 grade_gain = vec3(1.0);
uniform vec3 grade_gamma = vec3(1.0);
uniform vec3 grade_offset = vec3(0.0);
uniform float grade_contrast = 1.0;
uniform float grade_saturation = 1.0;
// Monochrome film in place of the saturation (native/xr-layer/picture_glsl.h's MONO_GLSL, same arithmetic):
// weights per channel and the chroma lift; S curve power, the exponent taking its pivot to 0.5, black point,
// paper white; grain amount, cell and
// this frame's pattern (mpv_video_display.gd moves it each frame; pip_shader.cmake's GLSL has no TIME).
uniform bool grade_mono = false;
uniform vec4 grade_mono_weights = vec4(0.2126, 0.7152, 0.0722, 0.0);
uniform vec4 grade_mono_tone = vec4(1.0, 1.0, 0.0, 1.0);
uniform vec3 grade_mono_grain = vec3(0.0, 1.0, 0.0);
// QIYU factory runtime only (color_grade.gd): its eye buffer shows encoded RGB washed out, as with
// browser pages (web_browser_page.gdshader). Decoding last keeps the grade's own controls unchanged.
uniform bool display_decode = false;
// QiyuController.DISPLAY_GAMMA: the decoded picture still shows dark on QIYU, so its midtones are lifted.
uniform float display_gamma = 1.0;
// QIYU with a linear 8-bit eye buffer (QiyuController.linear_eye_buffer): half a step of noise keeps
// the dark levels the decode would otherwise round together.
uniform bool display_dither = false;

float film_hash(vec2 p) {
	uvec2 q = uvec2(p) * uvec2(1597334673u, 3812015801u);
	return float((q.x ^ q.y) * 1597334673u) * (1.0 / 4294967296.0);
}

float film_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = p - i;
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(film_hash(i), film_hash(i + vec2(1.0, 0.0)), f.x), mix(film_hash(i + vec2(0.0, 1.0)), film_hash(i + vec2(1.0)), f.x), f.y);
}

vec3 film(vec3 c, vec2 frag) {
	float y = dot(c, grade_mono_weights.rgb);
	float chroma = max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b));
	y = clamp(y + grade_mono_weights.a * chroma * (0.6 + 0.4 * clamp(c.r - c.b, -1.0, 1.0)), 0.0, 1.0);
	float t = pow(y, grade_mono_tone.y);
	float s = pow(t, grade_mono_tone.x);
	y = pow(s / max(s + pow(1.0 - t, grade_mono_tone.x), 1e-5), 1.0 / grade_mono_tone.y);
	y = clamp((y - grade_mono_tone.z) / max(1.0 - grade_mono_tone.z, 1e-3), 0.0, 1.0) * grade_mono_tone.w;
	if (grade_mono_grain.x > 0.0) {
		y += grade_mono_grain.x * (film_noise(frag / max(grade_mono_grain.y, 1.0) + grade_mono_grain.z * vec2(37.0, 17.0)) - 0.5) * (0.35 + 2.6 * y * (1.0 - y));
	}
	return vec3(clamp(y, 0.0, 1.0));
}

vec3 color_grade(vec3 rgb, vec2 frag) {
	vec3 c = rgb;
	if (grade_enabled) {
		c = (rgb * grade_gain - vec3(0.5)) * grade_contrast + vec3(0.5) + grade_offset;
		c = pow(max(c, vec3(0.0)), grade_gamma);
		if (grade_mono) c = film(clamp(c, vec3(0.0), vec3(1.0)), frag);
		float luma = dot(c, vec3(0.2126, 0.7152, 0.0722));
		if (!grade_mono) c = clamp(mix(vec3(luma), c, grade_saturation), vec3(0.0), vec3(1.0));
	}
	if (display_decode) {
		c = pow(max(c, vec3(0.0)), vec3(display_gamma));
		c = mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(0.04045, c));
	}
	if (display_dither) { c = max(c + (fract(52.9829189 * fract(dot(frag, vec2(0.06711056, 0.00583715)))) - 0.5) / 255.0, vec3(0.0)); }
	return c;
}
