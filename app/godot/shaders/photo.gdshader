shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;
uniform sampler2D photo_texture : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D depth_texture : filter_linear, repeat_disable;
uniform sampler2D stereo_texture : source_color, filter_linear_mipmap, repeat_disable;
uniform bool photo_stereo = false;
uniform bool portrait_enabled = false;
uniform sampler2D portrait_texture : filter_linear_mipmap, repeat_disable;
uniform bool native_stereo = false;
uniform float spatial_disparity = 0.0;
uniform vec2 generated_size = vec2(1.0);
#include "res://shaders/video_coordinates.gdshaderinc"
#include "res://shaders/sharpness.gdshaderinc"
uniform vec2 crop_center = vec2(0.5);
uniform vec2 crop_aspect = vec2(1.0);
uniform vec2 crop_skew = vec2(0.0);
uniform float content_zoom = 1.0;
uniform vec4 pano_rect = vec4(0.0, 0.0, 1.0, 1.0);
uniform bool detail_projection = false;
uniform vec3 detail_forward = vec3(0.0, 0.0, -1.0);
uniform vec3 detail_right = vec3(1.0, 0.0, 0.0);
uniform vec3 detail_up = vec3(0.0, 1.0, 0.0);
uniform bool photo_depth = false;
uniform bool spatial_hidden = false;
uniform float depth_strength = 1.0;
uniform vec4 depth_rect = vec4(0.0, 0.0, 1.0, 1.0);
uniform int test_eye = -1;
uniform vec2 edge_feather = vec2(0.0);
uniform float presentation_opacity = 1.0;
uniform float reveal_progress = 1.0;
#include "res://shaders/photo_reveal.gdshaderinc"
// Compatibility fields for the shared photo API; full photos no longer draw a target frame.
uniform int target_state = 0;
uniform vec2 target_width = vec2(0.008);
// Surface UV rectangle shown by the compositor picture layer (zero size: none).
// The feathered edge around it remains in the eye buffers.
uniform vec4 layer_cut = vec4(0.0);
// Translation is part of the photo's eye-buffer draw, including its feathered rim.
uniform bool comic_overlay_enabled = false;
uniform sampler2D comic_overlay_texture : source_color, filter_linear, repeat_disable;

vec4 photo_color(vec2 p) {
	if (photo_stereo) {
		vec2 local = clamp(color_uv(p), vec2(0.5) / generated_size, vec2(1.0) - vec2(0.5) / generated_size);
		local.x = (local.x + float(eye_index)) * 0.5;
		return texture(stereo_texture, local);
	}
	return texture(photo_texture, color_uv(p));
}

void vertex() { eye_index = test_eye >= 0 ? test_eye : int(VIEW_INDEX); media_direction = VERTEX; }
void fragment() {
	if (spatial_hidden) { discard; }
	vec4 comic = comic_overlay_enabled ? texture(comic_overlay_texture, UV) : vec4(0.0);
	bool translated = comic.a > 0.5;
	if (!translated && layer_cut.z > 0.0 && all(greaterThanEqual(UV, layer_cut.xy)) && all(lessThanEqual(UV, layer_cut.xy + layer_cut.zw))) { discard; }
	vec3 direction = media_direction;
	if (detail_projection) {
		// Match the 0.8 x 0.5 m window at 1.4 m: 1x shows its natural angular coverage.
		vec2 p = (UV - vec2(0.5)) * vec2(0.8, -0.5) / (1.4 * content_zoom);
		direction = normalize(detail_forward + detail_right * p.x + detail_up * p.y);
	}
	vec2 shown = eye_uv(UV, direction);
	if (video_geometry == 0) {
		vec2 offset = shown - vec2(0.5);
		shown = crop_center + vec2(offset.x * crop_aspect.x + offset.y * crop_skew.x,
			offset.x * crop_skew.y + offset.y * crop_aspect.y) / content_zoom;
	}
	if (photo_depth && !photo_stereo && !stereo_sbs && video_geometry == 0) {
		vec2 fixed_uv = shown;
		for (int i = 0; i < 4; i++) {
			float near_value = texture(depth_texture, clamp(depth_rect.xy + shown * depth_rect.zw, depth_rect.xy, depth_rect.xy + depth_rect.zw)).r;
			shown.x = fixed_uv.x - (eye_index == 0 ? 1.0 : -1.0) * (near_value - 0.35) * 0.0175 * depth_strength;
		}
	}
	if (video_geometry == 3 && !stereo_sbs) { shown = (shown - pano_rect.xy) / pano_rect.zw; }
	if (native_stereo && stereo_sbs && !top_bottom && video_geometry == 0) {
		int source_eye = swap_eyes ? 1 - eye_index : eye_index;
		shown.x += (source_eye == 0 ? 0.5 : -0.5) * spatial_disparity;
	}
	bool outside = any(lessThan(shown, vec2(0.0))) || any(greaterThan(shown, vec2(1.0))) || outside_lens(direction);
	vec4 color = photo_color(shown);
	if (sharpness > 0.0) {
		vec2 step_uv = max(vec2(1.0) / view_size(), fwidth(shown));
		color.rgb = sharpen_rgb(color.rgb,
			photo_color(shown + vec2(0.0, step_uv.y)).rgb,
			photo_color(shown - vec2(0.0, step_uv.y)).rgb,
			photo_color(shown + vec2(step_uv.x, 0.0)).rgb,
			photo_color(shown - vec2(step_uv.x, 0.0)).rgb);
	}
	ALBEDO = outside ? vec3(0.0) : color.rgb;
	ALPHA = outside ? 1.0 : color.a;
	if (video_geometry == 0 && any(greaterThan(edge_feather, vec2(0.0)))) {
		// Surface UV is per eye, independent of packed SBS/TB and depth reprojection.
		vec2 fade = smoothstep(vec2(0.0), max(edge_feather, vec2(0.00001)), min(native_stereo ? shown : UV, vec2(1.0) - (native_stereo ? shown : UV)));
		ALPHA = outside ? 0.0 : color.a * fade.x * fade.y;
	}
	if (portrait_enabled) {
		vec2 mask_uv = clamp(color_uv(shown), vec2(0.5) / generated_size, vec2(1.0) - vec2(0.5) / generated_size);
		mask_uv.x = (mask_uv.x + float(eye_index)) * 0.5;
		ALPHA *= outside ? 0.0 : smoothstep(0.02, 0.98, texture(portrait_texture, mask_uv).r);
	}
	ALPHA *= presentation_opacity * photo_reveal_clear(UV, reveal_progress);
	// OCR masks must cover the source ink even at the image's soft outer edge.
	// Keep readable text on the screen plane while the photo uses generated stereo.
	if (translated) {
		// The viewport stores premultiplied colour; avoid a grey seam on white masks.
		ALBEDO = clamp(comic.rgb / max(comic.a, 0.001), vec3(0.0), vec3(1.0));
		ALPHA = 1.0;
	}
}
