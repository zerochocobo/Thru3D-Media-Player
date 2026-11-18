// Same display transform for decoder OES and inferred/packed color textures.
// Operates on decoded display RGB, after sampling; masks and model input are untouched.
uniform bool grade_enabled = false;
uniform vec3 grade_gain = vec3(1.0);
uniform vec3 grade_gamma = vec3(1.0);
uniform vec3 grade_offset = vec3(0.0);
uniform float grade_contrast = 1.0;
uniform float grade_saturation = 1.0;
// QIYU factory runtime only (color_grade.gd): its eye buffer shows encoded RGB washed out, as with
// browser pages (web_browser_page.gdshader). Decoding last keeps the grade's own controls unchanged.
uniform bool display_decode = false;

vec3 color_grade(vec3 rgb) {
	vec3 c = rgb;
	if (grade_enabled) {
		c = (rgb * grade_gain - vec3(0.5)) * grade_contrast + vec3(0.5) + grade_offset;
		c = pow(max(c, vec3(0.0)), grade_gamma);
		float luma = dot(c, vec3(0.2126, 0.7152, 0.0722));
		c = clamp(mix(vec3(luma), c, grade_saturation), vec3(0.0), vec3(1.0));
	}
	if (display_decode) { c = mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(0.04045, c)); }
	return c;
}
