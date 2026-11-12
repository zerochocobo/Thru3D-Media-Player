uniform vec4 slideshow_mapping = vec4(1.0, 0.0, 0.0, 1.0);
uniform float slideshow_mix = 1.0;
// 0 uniform crossfade, 1 soft wipe across the frame, 2 depth order (near first).
uniform int slideshow_style = 0;
// Depth order source: 0 none (crossfade), 1 incoming depth, 2 outgoing depth.
uniform int slideshow_depth_source = 0;
uniform sampler2D slideshow_old_texture : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D slideshow_old_depth_texture : filter_linear, repeat_disable;
uniform sampler2D slideshow_old_comic_overlay_texture : source_color, filter_linear, repeat_disable;
uniform vec4 slideshow_old_mapping = vec4(1.0, 0.0, 0.0, 1.0);
uniform int slideshow_old_layout = 0;
uniform bool slideshow_old_swap = false;
uniform vec2 slideshow_old_size = vec2(1.0);
uniform bool slideshow_old_depth = false;
uniform vec4 slideshow_old_depth_rect = vec4(0.0, 0.0, 1.0, 1.0);
uniform float slideshow_old_depth_strength = 1.0;
uniform float slideshow_old_depth_convergence = 0.35;
uniform float slideshow_old_disparity = 0.0;
uniform vec2 slideshow_old_edge_feather = vec2(0.0);
uniform float slideshow_old_sharpness = 0.0;
uniform bool slideshow_old_comic_overlay_enabled = false;

vec2 slideshow_uv(vec2 uv, vec4 mapping) {
	vec2 offset = uv - vec2(0.5);
	return vec2(dot(offset, mapping.xy), dot(offset, mapping.zw)) + vec2(0.5);
}

vec2 slideshow_old_eye_size() {
	return slideshow_old_size / vec2(slideshow_old_layout == 1 ? 2.0 : 1.0, slideshow_old_layout == 2 ? 2.0 : 1.0);
}

vec4 slideshow_old_color(vec2 uv) {
	vec2 size = slideshow_old_eye_size();
	uv = clamp(uv, vec2(0.5) / size, vec2(1.0) - vec2(0.5) / size);
	int eye = slideshow_old_swap ? 1 - eye_index : eye_index;
	if (slideshow_old_layout == 1) { uv.x = (uv.x + float(eye)) * 0.5; }
	if (slideshow_old_layout == 2) { uv.y = (uv.y + float(eye)) * 0.5; }
	return texture(slideshow_old_texture, uv);
}

vec4 slideshow_previous(vec2 uv) {
	vec2 surface = slideshow_uv(uv, slideshow_old_mapping);
	vec2 p = surface;
	if (slideshow_old_depth) {
		for (int i = 0; i < 4; i++) {
			float near_value = texture(slideshow_old_depth_texture, clamp(slideshow_old_depth_rect.xy + p * slideshow_old_depth_rect.zw,
				slideshow_old_depth_rect.xy, slideshow_old_depth_rect.xy + slideshow_old_depth_rect.zw)).r;
			p.x = surface.x - (eye_index == 0 ? 1.0 : -1.0) * (near_value - slideshow_old_depth_convergence) * 0.0175 * slideshow_old_depth_strength;
		}
	}
	int eye = slideshow_old_swap ? 1 - eye_index : eye_index;
	p.x += (eye == 0 ? 0.5 : -0.5) * slideshow_old_disparity;
	bool outside = any(lessThan(p, vec2(0.0))) || any(greaterThan(p, vec2(1.0)));
	vec4 color = slideshow_old_color(p);
	if (slideshow_old_sharpness > 0.0) {
		vec2 step_uv = max(vec2(1.0) / slideshow_old_eye_size(), fwidth(p));
		vec3 east = slideshow_old_color(p + vec2(step_uv.x, 0.0)).rgb;
		vec3 west = slideshow_old_color(p - vec2(step_uv.x, 0.0)).rgb;
		vec3 north = slideshow_old_color(p + vec2(0.0, step_uv.y)).rgb;
		vec3 south = slideshow_old_color(p - vec2(0.0, step_uv.y)).rgb;
		vec3 low = min(color.rgb, min(min(east, west), min(north, south)));
		vec3 high = max(color.rgb, max(max(east, west), max(north, south)));
		vec3 detail = color.rgb - (east + west + north + south) * 0.25;
		color.rgb = clamp(color.rgb + clamp(detail * slideshow_old_sharpness, vec3(-0.04), vec3(0.04)), low, high);
	}
	vec2 feather = smoothstep(vec2(0.0), max(slideshow_old_edge_feather, vec2(0.00001)), min(surface, vec2(1.0) - surface));
	color.a = outside ? 0.0 : color.a * feather.x * feather.y;
	if (slideshow_old_comic_overlay_enabled) {
		vec4 comic = texture(slideshow_old_comic_overlay_texture, surface);
		if (comic.a > 0.5) { color = vec4(clamp(comic.rgb / max(comic.a, 0.001), vec3(0.0), vec3(1.0)), 1.0); }
	}
	return color;
}

// Per-pixel progress: a soft band sweeps from 0 to 1 as the shared mix advances.
float slideshow_band(float mix_amount, float position, float softness) {
	return smoothstep(0.0, 1.0, clamp((mix_amount * (1.0 + softness) - position) / softness, 0.0, 1.0));
}

// Mix premultiplied samples, then return straight alpha for the existing blend_mix pass.
// Two independently fading surfaces would reveal the room midway through opaque photos.
vec4 slideshow_blend(vec4 old_color, vec4 new_color, float amount) {
	float alpha = mix(old_color.a, new_color.a, amount);
	vec3 rgb = mix(old_color.rgb * old_color.a, new_color.rgb * new_color.a, amount);
	return vec4(alpha > 0.00001 ? rgb / alpha : vec3(0.0), alpha);
}
