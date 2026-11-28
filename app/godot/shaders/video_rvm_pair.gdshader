shader_type spatial;
#include "res://shaders/color_grade.gdshaderinc"
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;

// Both textures belong to one immutable source ticket. Canonical row 0 is top.
uniform sampler2D color_texture : filter_linear, repeat_disable;
uniform sampler2D alpha_texture : filter_linear, repeat_disable;
uniform bool alpha_enabled = true;
// Eye-buffer playback (no compositor video layer): take the plain fast path in fragment().
uniform bool plain_fast_path = false;
// Debug A/B (perf_tune plain_footprint_taps): the fast path's footprint taps per axis, 0 = one bilinear tap.
uniform int plain_footprint_taps = 3;
// The player's edge feather/shrink: mask values remapped from [x, y] to [0, 1] ((0, 1): unchanged).
uniform vec2 alpha_edge = vec2(0.0, 1.0);
float edge_alpha(float m) { return clamp((m - alpha_edge.x) / max(alpha_edge.y - alpha_edge.x, 0.001), 0.0, 1.0); }
uniform vec2 model_size = vec2(256.0, 144.0);
uniform vec4 model_content_rect = vec4(0.0, 0.0, 1.0, 1.0);
// 2D->3D (mono sources): alpha_texture carries a near map (1 = nearest) instead of Alpha.
// Each eye samples the color shifted by its half of the parallax; depth_shift is the eye-width
// fraction between nearest and farthest, depth_convergence the near value left on the screen plane.
// Stereo focus (test): each eye's sphere moves onto that eye (model units) and scales to the focused depth.
uniform float focus_scale = 1.0;
uniform vec3 focus_offset = vec3(0.0);
// Keeps the viewer's place inside the scaled sphere (zoom and position move the sphere off the viewer).
uniform vec3 focus_centre = vec3(0.0);
uniform bool depth_enabled = false;
uniform float depth_shift = 0.035;
uniform float depth_convergence = 0.35;
// Alpha-packed fisheye files (DeoVR six-block layout, PTMediaServer "_FISHEYE_F180_alpha"): the
// mask is part of the color image itself; no model runs. packed_size is in the include.
uniform bool packed_alpha = false;
#include "res://shaders/video_coordinates.gdshaderinc"
#include "res://shaders/video_pip_coordinates.gdshaderinc"
#include "res://shaders/sharpness.gdshaderinc"
#include "res://shaders/projected_subtitles.gdshaderinc"
#include "res://shaders/bitmap_subtitles.gdshaderinc"
uniform bool separate_subtitles = false;
uniform bool projection_mesh = false;
uniform bool projection_uv_packed = false;

vec3 clarity_sample(vec2 p, vec2 lo, vec2 hi, vec3 center) {
	vec2 q = clamp(p, lo, hi);
	if (packed_alpha && reserved_color(q)) { return center; }
	return texture(color_texture, q).rgb;
}

// An in-scene screen (beach, cinema hall) can show several source texels per eye pixel. The video
// has no mipmaps, so one bilinear tap skips most of them and fine edges crawl. Box-filter the pixel's
// footprint instead: each tap sits on a texel corner and so averages exactly 2x2 texels, and taps two
// texels apart tile the box without gaps. dx/dy come from uniform control flow. Layers filter themselves.
vec3 footprint_taps_color(vec2 p, vec2 dx, vec2 dy, vec2 lo, vec2 hi, vec3 center, int max_taps) {
	vec2 span = (abs(dx) + abs(dy)) * source_size;
	// A wrap seam, not a footprint: its derivative spans a large part of the frame.
	if (max(span.x, span.y) > 32.0) { return center; }
	ivec2 taps = ivec2(clamp(ceil(span * 0.5), vec2(1.0), vec2(float(max_taps))));
	if (taps.x * taps.y == 1 && max(span.x, span.y) < 1.5) { return center; }
	vec2 corner = floor(p * source_size + 0.5);
	vec3 sum = vec3(0.0);
	for (int i = 0; i < taps.x; i++) {
		for (int j = 0; j < taps.y; j++) {
			vec2 texel = corner + vec2(float(2 * i - taps.x + 1), float(2 * j - taps.y + 1));
			sum += clarity_sample(texel / source_size, lo, hi, center);
		}
	}
	return sum / float(taps.x * taps.y);
}
vec3 footprint_color(vec2 p, vec2 dx, vec2 dy, vec2 lo, vec2 hi, vec3 center) {
	return footprint_taps_color(p, dx, dy, lo, hi, center, 3);
}

vec2 raw_eye_uv(vec2 displayed_uv) {
	vec2 p = displayed_uv;
	if (rotation_degrees == 90) { p = vec2(p.y, 1.0 - p.x); }
	else if (rotation_degrees == 180) { p = vec2(1.0) - p; }
	else if (rotation_degrees == 270) { p = vec2(1.0 - p.y, p.x); }
	return p;
}

#include "res://shaders/text_protection.gdshaderinc"

float near_at(vec2 uv) {
	vec2 p = clamp(model_content_rect.xy + uv * model_content_rect.zw, vec2(0.5) / model_size, vec2(1.0) - vec2(0.5) / model_size);
	return protected_near(texture(alpha_texture, vec2(p.x * 0.5, p.y)).r, uv);
}

// Inverse warp: find the source point whose own parallax lands here, so near edges move with
// their object instead of with whatever lies beside them. The limited near map makes the landing
// position monotone in the source, so bisect its bracket (near 0..1): three fixed-point steps
// oscillated beside edges and, by step parity, streaked or smeared hair at the position extremes.
vec2 depth_parallax(vec2 shown, int view) {
	float side = view == 0 ? 1.0 : -1.0; // left eye: near content moves right, in front of the screen
	float k = depth_shift * 0.5;
	float a = shown.x - side * (1.0 - depth_convergence) * k, b = shown.x + side * depth_convergence * k;
	float lo = min(a, b), hi = max(a, b);
	vec2 p = shown;
	for (int i = 0; i < 6; i++) {
		p.x = 0.5 * (lo + hi);
		if (p.x + side * (near_at(raw_eye_uv(p)) - depth_convergence) * k > shown.x) { hi = p.x; } else { lo = p.x; }
	}
	// One fixed-point step from beside the root: exact where text protection holds the screen plane.
	p.x = 0.5 * (lo + hi);
	p.x = shown.x - side * (near_at(raw_eye_uv(p)) - depth_convergence) * k;
	return p;
}

vec2 packed_texel(vec2 mask_pixel) {
	float half_w = packed_size.x * 0.5;
	float quarter_w = packed_size.x * 0.25;
	float half_h = packed_size.y * 0.5;
	float y = mask_pixel.y < half_h ? source_size.y - half_h + mask_pixel.y : mask_pixel.y - half_h;
	float x;
	if (mask_pixel.x < half_w) { x = source_size.x * 0.5 - half_w * 0.5 + mask_pixel.x; }
	else if (mask_pixel.x < half_w + quarter_w) { x = source_size.x - quarter_w + mask_pixel.x - half_w; }
	else { x = mask_pixel.x - half_w - quarter_w; }
	return (vec2(x, y) + vec2(0.5)) / source_size;
}

float packed_sample(vec2 mask_pixel) {
	return texture(color_texture, packed_texel(mask_pixel)).r;
}

// Four taps stay inside their own tiles and this eye's half (as video_alpha_oes.gdshader).
float packed_mask(vec2 full_uv, int eye) {
	vec2 p = clamp(full_uv * packed_size - vec2(0.5), vec2(0.0), packed_size - vec2(1.0));
	if (stereo_sbs) {
		float eye_start = float(eye) * packed_size.x * 0.5;
		p.x = clamp(p.x, eye_start, eye_start + packed_size.x * 0.5 - 1.0);
	}
	vec2 a = floor(p);
	vec2 b = min(a + vec2(1.0), packed_size - vec2(1.0));
	vec2 f = fract(p);
	return mix(mix(packed_sample(a), packed_sample(vec2(b.x, a.y)), f.x),
		mix(packed_sample(vec2(a.x, b.y)), packed_sample(b), f.x), f.y);
}

void vertex() {
	eye_index = int(VIEW_INDEX);
	media_direction = VERTEX;
	VERTEX = VERTEX * focus_scale + focus_centre + (eye_index == 0 ? -focus_offset : focus_offset);
	subtitle_patch_position = vec3(0.0);
	subtitle_patch_eye = vec3(0.0);
	if (subtitle_enabled && !separate_subtitles) {
		subtitle_patch_position = (subtitle_world_to_patch * MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
		subtitle_patch_eye = (subtitle_world_to_patch * INV_VIEW_MATRIX * vec4(EYE_OFFSET, 1.0)).xyz;
	}
}

// QIYU flat playback: the bridge's 2x box reductions of this frame (1/2 .. 1/16 size). A minified
// picture then blends two levels near its pixel size (trilinear) instead of box-filtering many
// full-size texels with most fetches missing the cache. Godot keeps a borrowed texture to its base
// level, so each level is a texture of its own. Declared after vertex(): the PiP atlas leaves it out.
uniform int color_levels = 0;
uniform sampler2D color_level_1 : filter_linear, repeat_disable;
uniform sampler2D color_level_2 : filter_linear, repeat_disable;
uniform sampler2D color_level_3 : filter_linear, repeat_disable;
uniform sampler2D color_level_4 : filter_linear, repeat_disable;
// [lo, hi]: the eye's region of the frame. The bridge sizes level k as floor(size / 2^k).
vec3 level_tap(int level, vec2 p, vec2 lo, vec2 hi) {
	vec2 half_texel = 0.5 / max(floor(source_size / exp2(float(level))), vec2(1.0));
	vec2 q = clamp(p, lo + half_texel, hi - half_texel);
	if (level == 1) { return textureLod(color_level_1, q, 0.0).rgb; }
	if (level == 2) { return textureLod(color_level_2, q, 0.0).rgb; }
	if (level == 3) { return textureLod(color_level_3, q, 0.0).rgb; }
	return textureLod(color_level_4, q, 0.0).rgb;
}
// A picture shown at [p] (this eye's texel-centre bounds [lo, hi], derivatives dx, dy): blended from the two
// reductions nearest its pixel size where the bridge made them and it is minified 2x to 32x, otherwise
// one bilinear tap box-filtered over its footprint (at most max_taps per axis; 0: the tap alone).
// The plain path and the generated depth variant (PairTextureBinding.depth_code) draw with it.
vec3 minified_color(vec2 p, vec2 dx, vec2 dy, vec2 lo, vec2 hi, int max_taps) {
	vec2 span = (abs(dx) + abs(dy)) * source_size;
	float texels = max(span.x, span.y);
	if (color_levels > 0 && texels > 2.0 && texels <= 32.0) {
		float lod = min(log2(texels), float(color_levels));
		int level = min(int(lod), color_levels);
		vec2 eye_lo = lo - 0.5 / source_size;
		vec2 eye_hi = hi + 0.5 / source_size;
		vec3 rgb = level_tap(level, p, eye_lo, eye_hi);
		if (level < color_levels) { rgb = mix(rgb, level_tap(level + 1, p, eye_lo, eye_hi), lod - float(level)); }
		return rgb;
	}
	vec3 center = texture(color_texture, p).rgb;
	return max_taps > 0 ? footprint_taps_color(p, dx, dy, lo, hi, center, max_taps) : center;
}

void fragment() {
	if (near_side(media_direction)) { discard; }
	// Plain playback (no mask, depth, PiP, packed Alpha, stream mesh or sharpening): projection, eye,
	// alignment, footprint, grade and captions only. Quest 2 stand-in for QIYU A091, 8K VR180 in the eye
	// buffer at 1.00x: 24.9 ms GPU on the full body below, 16.3 ms on this path (2026-11-25).
	if (!alpha_enabled && !depth_enabled && !pip_enabled && !packed_alpha && !projection_mesh && !projection_uv_packed
			&& sharpness <= 0.0 && plain_fast_path) {
		vec2 plain_uv = eye_uv(UV, media_direction);
		vec2 plain_shown = aligned_eye_uv(plain_uv);
		int plain_eye = source_eye();
		vec2 plain_size = view_size();
		vec2 plain_p = clamp(raw_eye_uv(plain_shown), vec2(0.5) / plain_size, vec2(1.0) - vec2(0.5) / plain_size);
		vec2 plain_lo = vec2(0.5) / source_size;
		vec2 plain_hi = vec2(1.0) - plain_lo;
		if (stereo_sbs && top_bottom) {
			plain_p.y = (plain_p.y + float(plain_eye)) * 0.5; plain_lo.y += float(plain_eye) * 0.5; plain_hi.y -= float(1 - plain_eye) * 0.5;
		} else if (stereo_sbs) {
			plain_p.x = (plain_p.x + float(plain_eye)) * 0.5; plain_lo.x += float(plain_eye) * 0.5; plain_hi.x -= float(1 - plain_eye) * 0.5;
		}
		vec2 plain_dx = dFdx(plain_p);
		vec2 plain_dy = dFdy(plain_p);
		vec3 plain_rgb = minified_color(plain_p, plain_dx, plain_dy, plain_lo, plain_hi, plain_footprint_taps);
		ALBEDO = outside_lens(media_direction) || outside_alignment(plain_shown) ? vec3(0.0) : color_grade(plain_rgb, FRAGCOORD.xy);
		ALPHA = 1.0;
		if (!separate_subtitles) {
			vec4 plain_caption = caption_composite(ALBEDO, ALPHA, projected_caption());
			plain_caption = caption_composite(plain_caption.rgb, plain_caption.a, bitmap_caption(raw_eye_uv(plain_uv)));
			ALBEDO = plain_caption.rgb;
			ALPHA = plain_caption.a;
		}
	} else { // Full path. pip_shader.cmake builds the compositor PiP shader from here on.
	if (projection_mesh && abs(COLOR.r - float(source_eye())) > 0.25) { discard; }
	vec3 sample_direction = pip_direction(UV, media_direction);
	vec2 shown_uv = projection_mesh ? UV : eye_uv(pip_uv(UV), sample_direction);
	shown_uv = aligned_eye_uv(shown_uv);
	if (depth_enabled && !stereo_sbs && !pip_enabled) { shown_uv = depth_parallax(shown_uv, pip_viewing_eye > 0 ? pip_viewing_eye - 1 : eye_index); }
	vec2 local_uv = raw_eye_uv(shown_uv);
	int eye = source_eye();
	vec2 eye_size = projection_uv_packed ? source_size : view_size();
	vec2 color_p = clamp(local_uv, vec2(0.5) / eye_size, vec2(1.0) - vec2(0.5) / eye_size);
	if (!projection_uv_packed && stereo_sbs && top_bottom) { color_p.y = (color_p.y + float(eye)) * 0.5; }
	else if (!projection_uv_packed && stereo_sbs) { color_p.x = (color_p.x + float(eye)) * 0.5; }
	vec3 rgb = texture(color_texture, color_p).rgb;
	vec2 color_dx = dFdx(color_p);
	vec2 color_dy = dFdy(color_p);
	vec2 lo = vec2(0.5) / source_size;
	vec2 hi = vec2(1.0) - lo;
	if (stereo_sbs && top_bottom) { lo.y += float(eye) * 0.5; hi.y -= float(1 - eye) * 0.5; }
	else if (stereo_sbs) { lo.x += float(eye) * 0.5; hi.x -= float(1 - eye) * 0.5; }
	if (!projection_mesh) { rgb = footprint_color(color_p, color_dx, color_dy, lo, hi, rgb); }
	if (sharpness > 0.0 && !projection_mesh) {
		vec2 step_uv = max(vec2(1.0) / source_size, fwidth(color_p));
		rgb = sharpen_rgb(rgb, clarity_sample(color_p + vec2(0.0, step_uv.y), lo, hi, rgb),
			clarity_sample(color_p - vec2(0.0, step_uv.y), lo, hi, rgb),
			clarity_sample(color_p + vec2(step_uv.x, 0.0), lo, hi, rgb),
			clarity_sample(color_p - vec2(step_uv.x, 0.0), lo, hi, rgb));
	}
	// The model input contains letterbox padding. Read only centers inside content,
	// then clamp within this eye before packing; never interpolate across the seam.
	vec2 first_center = (ceil(model_content_rect.xy * model_size - vec2(0.5)) + vec2(0.5)) / model_size;
	vec2 last_center = (floor((model_content_rect.xy + model_content_rect.zw) * model_size - vec2(0.5)) + vec2(0.5)) / model_size;
	// An ROI window covers the whole model; keep sampling on this eye's own centers.
	first_center = max(first_center, vec2(0.5) / model_size);
	last_center = min(last_center, vec2(1.0) - vec2(0.5) / model_size);
	vec2 model_p = model_content_rect.xy + local_uv * model_content_rect.zw;
	// Outside the ROI window nothing was inferred: show passthrough, never an edge smear.
	bool outside = any(lessThan(model_p, vec2(0.0))) || any(greaterThan(model_p, vec2(1.0)));
	vec2 alpha_p = clamp(model_p, first_center, last_center);
	alpha_p.x = (alpha_p.x + float(eye)) * 0.5;
	ALBEDO = outside_lens(sample_direction) ? vec3(0.0) : color_grade(rgb, FRAGCOORD.xy);
	if (packed_alpha && stereo_sbs && !top_bottom) {
		// Pixels that carry the mask had their color overwritten by the packer.
		// (No early return: Godot writes the outputs after this function body.)
		ALPHA = reserved_color(color_p) ? 0.0 : edge_alpha(packed_mask(color_p, eye));
	} else {
		ALPHA = alpha_enabled && !depth_enabled ? (outside ? 0.0 : edge_alpha(texture(alpha_texture, alpha_p).r)) : 1.0;
	}
	// Crop correction borders rather than stretching an edge or reading the other eye.
	if (outside_alignment(shown_uv)) { ALBEDO = vec3(0.0); ALPHA = alpha_enabled || packed_alpha ? 0.0 : 1.0; }
	if (pip_outside(sample_direction, shown_uv)) { ALBEDO = vec3(0.0); ALPHA = alpha_enabled || packed_alpha ? 0.0 : 1.0; }
	if (!separate_subtitles) {
	vec4 composed = caption_composite(ALBEDO, ALPHA, projected_caption());
	composed = caption_composite(composed.rgb, composed.a, bitmap_caption(raw_eye_uv(eye_uv(UV, media_direction))));
	ALBEDO = composed.rgb;
	ALPHA = composed.a;
	}
	// Eye-buffer PiP only: native atlas extraction ends before the caption block.
	// Native centres retain their source; their narrow ring uses this same material.
	if (pip_enabled) {
		vec2 fade = smoothstep(vec2(0.0), max(pip_edge_feather, vec2(0.00001)), min(UV, vec2(1.0) - UV));
		ALPHA *= fade.x * fade.y;
	}
	}
}
