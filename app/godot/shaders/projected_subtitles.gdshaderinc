uniform sampler2D subtitle_texture : source_color, filter_linear, repeat_disable;
uniform bool subtitle_enabled = false;
uniform mat4 subtitle_world_to_patch = mat4(1.0);
uniform float subtitle_patch_half_extent = 0.35;
varying vec3 subtitle_patch_position;
varying flat vec3 subtitle_patch_eye;

vec4 projected_caption() {
	if (!subtitle_enabled) { return vec4(0.0); }
	// Intersect this physical eye's ray through the projected video pixel with one shared plane.
	// The video's fisheye/equirectangular source mapping remains in eye_uv; no angular shift.
	vec3 ray = subtitle_patch_position - subtitle_patch_eye;
	if (abs(ray.z) < 0.00001) { return vec4(0.0); }
	float t = -subtitle_patch_eye.z / ray.z;
	if (t <= 0.0) { return vec4(0.0); }
	vec2 hit = subtitle_patch_eye.xy + ray.xy * t;
	vec2 p = vec2(0.5) + vec2(hit.x, -hit.y) / (2.0 * subtitle_patch_half_extent);
	if (any(lessThan(p, vec2(0.0))) || any(greaterThan(p, vec2(1.0)))) { return vec4(0.0); }
	return texture(subtitle_texture, p);
}

vec4 caption_composite(vec3 video_rgb, float video_alpha, vec4 caption) {
	// A transparent canvas viewport contains premultiplied RGB; convert back for blend_mix.
	float a = caption.a + video_alpha * (1.0 - caption.a);
	vec3 rgb = caption.rgb + video_rgb * video_alpha * (1.0 - caption.a);
	return vec4(a > 0.0001 ? rgb / a : vec3(0.0), a);
}
