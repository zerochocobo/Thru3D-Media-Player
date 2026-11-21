// The effect was first contributed by ghanshyam (github.com/ghanshyamv1) in public PR #9.
// The curves in this shader were rewritten for 0.18.1.1.
shader_type spatial;
// Video-coloured halo around a flat screen.
// It writes premultiplied colour with alpha, so the compositor dims the room
// behind the glow and adds the picture's edge colour: light spilling from the screen.
// Lengths are in screen heights; `unit` is one screen height in metres.
render_mode unshaded, blend_premul_alpha, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

// Colours around the picture's border, clockwise from the top-left corner, a quarter a side.
uniform vec3 bar[32];
uniform float unit = 1.0;
// Half the picture's width, in screen heights.
uniform float half_width = 0.889;
// The falloff past the picture's edge: peak / (1 + (d / width)^power)^(1 / power).
uniform float peak = 0.95;
uniform float width = 0.063;
uniform float power = 1.5;
uniform float strength = 1.0;
// Screen heights past the picture where the mesh ends; the glow fades to nothing before it.
uniform float extent = 3.0;
// The picture's outer band that dissolves into the halo, and the radius of its corners.
// Zero while the picture keeps its hard edge: the halo then follows the square corners.
uniform float band = 0.1;
// Bright colours are held back: colour / (1 + hold * luminance). Least in the picture's own
// band, more at its edge, and most far from it, where a wide glow would wash the room out;
// the hold moves from near to far over about `hold_span` screen heights.
uniform float hold_edge = 0.65;
uniform float hold_near = 1.3;
uniform float hold_far = 2.9;
uniform float hold_span = 0.08;
uniform float edge_gain = 1.3;
// 0: the halo outside the picture. 1: the edge dissolve inside it, drawn only when the viewer
// asks for a soft edge. The picture is an opaque compositor layer and cannot fade itself, so
// its outer band is covered by the glow colour instead, meeting the halo without a seam.
uniform int part = 0;
// The halo's curves give display-referred values, so the colour is sRGB-encoded on every
// background: stored as it is (false) the halo shows at about a fifth of its brightness.
uniform bool display_referred = true;
// How much of the background the halo takes away where it shines. The camera picture is dimmed
// in full; a rendered background mostly keeps its own light, or a dark picture would smudge it.
uniform float dimming = 1.0;

varying vec2 local;
// The halo is smooth, so part 0 is shaded per vertex of a mesh that is dense near the picture:
// its fragments only blend.
varying vec4 shade;

// The border colour in the direction of `point` from the picture's centre.
vec3 border_colour(vec2 point) {
	vec2 p = point / vec2(half_width, 0.5);
	vec2 edge = p / max(max(abs(p.x), abs(p.y)), 1e-6);
	float u;
	if (abs(p.x) < abs(p.y)) {
		u = p.y > 0.0 ? 0.125 * (edge.x + 1.0) : 0.5 + 0.125 * (1.0 - edge.x);
	} else {
		u = p.x > 0.0 ? 0.25 + 0.125 * (1.0 - edge.y) : 0.75 + 0.125 * (edge.y + 1.0);
	}
	float at = mod(u * 32.0 - 0.5, 32.0);
	int first = int(floor(at));
	return mix(bar[first % 32], bar[(first + 1) % 32], at - float(first));
}

// Signed distance to the picture with rounded corners: negative inside.
float picture_distance(vec2 point) {
	vec2 q = abs(point) - vec2(half_width, 0.5) + band;
	return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - band;
}

vec3 encode(vec3 colour) {
	if (!display_referred) { return colour; }
	return mix(colour * 12.92, 1.055 * pow(colour, vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), colour));
}

// Premultiplied colour and alpha of the halo at a point outside the picture.
vec4 halo(vec2 point) {
	float d = max(picture_distance(point), 0.0);
	float level = peak / pow(1.0 + pow(d / width, power), 1.0 / power);
	level *= (1.0 - smoothstep(0.7 * extent, extent, d)) * strength;
	vec3 colour = border_colour(point);
	float luminance = dot(colour, vec3(0.2126, 0.7152, 0.0722));
	colour /= 1.0 + mix(hold_far, hold_near, 1.0 / (1.0 + d / hold_span)) * luminance;
	// The compositor adds the eye buffer's colour as stored and keeps (1 - alpha) of the room.
	return vec4(encode(min(colour * level, vec3(1.0))), clamp(level, 0.0, 1.0) * dimming);
}

void vertex() {
	local = VERTEX.xy / unit;
	shade = part == 0 ? halo(local) : vec4(0.0);
}

void fragment() {
	vec4 result = shade;
	if (part == 1) {
		// 0 at the band's inner side, 1 at the picture's edge and past its rounded corners.
		float across = clamp(1.0 + picture_distance(local) / band, 0.0, 1.0);
		float cover = across * smoothstep(0.0, 1.0, across) * strength;
		if (cover <= 0.001) { discard; }
		vec3 colour = border_colour(local);
		colour *= edge_gain / (1.0 + hold_edge * dot(colour, vec3(0.2126, 0.7152, 0.0722)));
		result = vec4(encode(min(colour * cover, vec3(1.0))), cover);
	}
	ALBEDO = result.rgb;
	ALPHA = result.a;
}
