// Originally contributed by ghanshyam (github.com/ghanshyamv1) in public PR #9.
shader_type spatial;
// Video-coloured halo around a flat screen over passthrough.
// It writes premultiplied colour with alpha, so the compositor dims the room
// behind the glow and adds the picture's edge colour: light spilling from the screen.
// Lengths are in halo units (a 16:9 screen is 1.92 x 1.08 units); `unit` converts
// metres, so the glow scales with the screen.
render_mode unshaded, blend_premul_alpha, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform vec3 bar[32];
uniform float unit = 1.25;
uniform float half_width = 0.96;
uniform float half_height = 0.54;
uniform float horizontal_disparity = 0.015;
uniform float immersive = 0.0;
uniform float slider_value = 0.4;
uniform float strength = 1.0;
// Halo units past the picture where the quad ends; the glow fades to nothing before it.
uniform float reach = 29.0;
// Overall brightness of the halo.
uniform float gain = 1.25;
// 0: the halo outside the picture. 1: the edge dissolve inside it: the outer 0.12 units of
// the picture, with rounded corners, fade as 1 - (d / 0.12)^2 so the picture has no hard
// border. The picture is an opaque compositor layer and cannot fade itself,
// so the band is covered by the glow colour instead, meeting the halo without a seam.
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

vec3 bar_at(float u) {
	float f = mod(u * 32.0 - 0.5, 32.0);
	int i0 = int(floor(f));
	int i1 = (i0 + 1) % 32;
	return mix(bar[i0], bar[i1], f - float(i0));
}

// Premultiplied colour and alpha at a point; `cover` is the picture's own share in part 1.
vec4 halo(vec2 point, float cover) {
	float W = half_width;
	float H = half_height;
	float X = point.x;
	float Y = point.y;

	// Perimeter coordinate, the same walk as the sampled bar: left edge 0..0.25 upwards,
	// top 0.25..0.5, right edge 0.5..0.75 downwards, bottom 0.75..1.
	float Xr = X * (H + 0.0001) / W;
	float r = min(abs(Y), abs(Xr)) / max(max(abs(Y), abs(Xr)), 1e-6);
	float s = sign(Y) * r * sign(Xr);
	float u;
	if (abs(Y) < abs(Xr)) {
		u = Xr < 0.0 ? 0.125 - 0.125 * s : 0.625 - 0.125 * s;
	} else {
		u = Y > 0.0 ? 0.375 + 0.125 * s : 0.875 + 0.125 * s;
	}
	vec3 c = bar_at(u);
	float L = 1.0 - 1.0 / (1.0 + c.r + c.g + 2.0 * min(c.r, c.g));

	// Rounded-rectangle distance, corner radius 0.08.
	float a = abs(Y) - (H - 0.08);
	float b = abs(X) + horizontal_disparity * W - (W - 0.08);
	float diff = b - a;
	float circ = 0.5 * (a + b - sqrt(0.0128 - diff * diff));
	float inner = abs(diff) < 0.08 ? circ : -min(abs(a - 0.08), abs(b - 0.08));
	float outside = length(max(vec2(b, a), vec2(0.0))) - 0.08;
	float d = outside > 0.0 ? outside : inner;

	// Immersive profile (0 for a flat screen).
	float e = d - 0.0428571440279483795166015625;
	float g1 = e < -0.085714288055896759033203125 ? 1.0 : (e > 0.0 ? 0.7 / (10.0 * e + 1.0) : 1.0 - 0.833333313465118408203125 * (7.0 * e + 0.6) * (7.0 * e + 0.6));

	// Flat profile: 0.6 at the edge, then 0.6 / (1 + 16 d).
	float m3 = immersive;
	float A1 = (1.0 - slider_value) * 3.5 - 14.5;
	float A2 = (1.0 - slider_value) * -0.6 + 1.0;
	float K = m3 * A1 + 16.0;
	float px = 0.4 - 0.1 * m3;
	float py = 0.084 + 0.116 * m3;
	float v90 = (px * -2.0) / K / (1.0 - px);
	float x52 = v90 * (A2 * m3) + d;
	float q = 1.0 - clamp(-d / py, 0.0, 1.0);
	float inside = 1.0 - pow(x52 * K * (1.0 - px) + 2.0 * px, 2.0) / (px * 4.0);
	float g2 = x52 > 0.0 ? (1.0 - px) / (K * x52 + 1.0) : (x52 < v90 ? 1.0 : inside);
	float g = m3 * g1 + g2 * (1.0 - m3);

	float f = 1.0 - L * ((1.0 - g) * 0.6 + 0.4);
	float w = 4.0 * q * q * q - 3.0 * q * q * q * q;
	// Premultiplied output (colour * a, a): measured on a Quest 3, the compositor
	// adds the eye buffer's colour as stored and keeps (1 - a) of the room. The eye buffer takes
	// display-referred values (linear output showed at about a fifth of the intended brightness),
	// so the premultiplied linear colour is sRGB-encoded.
	// The gain multiplies the premultiplied result once: colour and alpha both
	// carry it, and each is clamped on its own. (Clamping alpha first and then multiplying the
	// gained colour by it applied the gain twice outside the saturated ring, which showed as a
	// second rounded border where the ring ends.)
	float spread = part == 1 ? 1.0 - cover : g2 * w * gain * (1.0 - smoothstep(0.7 * reach, reach, max(d, 0.0)));
	float alpha = clamp(spread * strength, 0.0, 1.0) * (part == 1 ? 1.0 : dimming);
	vec3 colour = min(f * c * (part == 1 ? gain * spread : spread) * strength, vec3(1.0));
	if (display_referred) {
		colour = mix(colour * 12.92, 1.055 * pow(colour, vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), colour));
	}
	return vec4(colour, alpha);
}

void vertex() {
	local = VERTEX.xy / unit;
	shade = part == 0 ? halo(local, 1.0) : vec4(0.0);
}

void fragment() {
	vec4 result = shade;
	if (part == 1) {
		if (abs(local.x) >= half_width || abs(local.y) >= half_height) { discard; }
		vec2 qq = max(abs(local) - vec2(half_width - 0.12, half_height - 0.12), vec2(0.0));
		float dd = length(qq) / 0.12;
		float cover = clamp(1.0 - dd * dd, 0.0, 1.0);
		if (cover >= 0.999) { discard; }
		result = halo(local, cover);
	}
	ALBEDO = result.rgb;
	ALPHA = result.a;
}
