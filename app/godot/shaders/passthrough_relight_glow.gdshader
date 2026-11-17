shader_type spatial;
// Video-coloured halo around a flat screen over passthrough (see docs/PASSTHROUGH_RELIGHT.md).
// Output is premultiplied colour with alpha: the compositor keeps (1 - a) of the room and adds
// the colour, so the glow dims the room a little and spills the picture's edge colour into it.
// Lengths are in halo units (a 16:9 screen is 1.92 x 1.08 units); `unit` converts metres,
// so the glow scales with the screen.
render_mode unshaded, blend_premul_alpha, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

// 32 edge colours walking the picture's perimeter (see passthrough_relight_model.gd).
uniform vec3 bar[32];
uniform float unit = 1.25;
uniform float half_width = 0.96;
uniform float half_height = 0.54;
// Fade distance of the glow, in halo units (Model.halo_reach).
uniform float reach = 0.36;
// Glow opacity right at the picture's edge (1 meets the edge band without a step).
uniform float peak = 1.0;
// Brightness of the added colour.
uniform float gain = 1.25;
uniform float strength = 1.0;
// 0: the halo outside the picture. 1: the edge dissolve on the outer `band` of the picture.
uniform int part = 0;
uniform float band = 0.12;
uniform float corner_radius = 0.08;
// The picture under the edge dissolve is drawn in the eye buffer (2D to 3D), not on a compositor
// layer. The GPU then blends in display space, where encoded premultiplied colour adds more light
// than its alpha removes, so the band instead writes encode(colour) * alpha (a plain fade) and is
// fully opaque over the outer 15 % of its width, hiding the picture's own border pixels.
uniform bool display_blend = false;
// Halo only: how far, in halo units, it reaches under the picture's edge. A picture drawn in the
// eye buffer is drawn over the halo, and without this a thin line of room shows between them.
uniform float overlap = 0.0;

varying vec2 local;

void vertex() {
	local = VERTEX.xy / unit;
}

vec3 bar_at(float u) {
	float x = fract(u) * 32.0 - 0.5;
	float i = floor(x);
	int a = int(mod(i, 32.0));
	int b = int(mod(i + 1.0, 32.0));
	return mix(bar[a], bar[b], x - i);
}

// Perimeter coordinate of the nearest picture edge, the same walk as the bar:
// left edge 0..0.25 upwards, top 0.25..0.5, right edge 0.5..0.75 downwards, bottom 0.75..1.
float perimeter_u(vec2 p, vec2 size) {
	vec2 n = p / size;
	vec2 c = clamp(n, vec2(-1.0), vec2(1.0));
	if (abs(n.x) >= abs(n.y)) {
		return n.x < 0.0 ? 0.125 + 0.125 * c.y : 0.625 - 0.125 * c.y;
	}
	return n.y > 0.0 ? 0.375 + 0.125 * c.x : 0.875 - 0.125 * c.x;
}

// Signed distance to a rounded rectangle (negative inside).
float rounded_box(vec2 p, vec2 size, float r) {
	vec2 q = abs(p) - (size - vec2(r));
	return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - r;
}

vec3 srgb_encode(vec3 c) {
	return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), c));
}

void fragment() {
	vec2 size = vec2(half_width, half_height);
	if (part == 1) {
		if (!all(lessThan(abs(local), size))) { discard; }
	} else if (all(lessThan(abs(local), size - vec2(overlap)))) {
		discard;
	}

	float d = rounded_box(local, size, corner_radius);
	// Halo: flat for about `reach` units past the edge (so it continues the edge band
	// smoothly), then a long soft tail that falls as reach / d into the room.
	float x = max(d, 0.0) / reach;
	float glow = peak / pow(1.0 + x * x * x * x, 0.25);
	if (part == 1) {
		// Inside the picture: fully opaque glow colour at the edge, so the picture's hard border
		// never shows, falling off quadratically so most of the band is already picture, and
		// reaching full picture `band` units in.
		float t = clamp(-d / band, 0.0, 1.0);
		if (display_blend) { t = clamp((t - 0.15) / 0.85, 0.0, 1.0); }
		if (t >= 0.999) { discard; }
		glow = (1.0 - t) * (1.0 - t);
	}

	vec3 c = bar_at(perimeter_u(local, size));
	// Soft highlight compression: bright edge colours are toned down (white to about 83 %),
	// so the glow never looks brighter than the picture.
	c *= gain / (1.0 + 0.5 * dot(c, vec3(0.2126, 0.7152, 0.0722)));
	float a = glow * strength;
	bool plain_fade = part == 1 && display_blend;
	ALPHA = clamp(a, 0.0, 1.0);
	// The Quest eye buffer takes display-referred values (measured on a Quest 3), so the
	// premultiplied linear colour is sRGB-encoded.
	ALBEDO = plain_fade ? srgb_encode(min(c, vec3(1.0))) * a : srgb_encode(min(c * a, vec3(1.0)));
}
