shader_type spatial;
// Wrist watch face, its projection cone and the control disc on top of it. One shader with
// several surface kinds so every element shares the palette, the glow falloff and the projector
// flicker. Real hands still occlude it through the depth test.
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix, shadows_disabled, fog_disabled;

const int FACE = 0;
const int RING = 1;
const int BUTTON = 2;
const int GUIDE = 3;
const int CONE = 4;
const int CURSOR = 5;
const int PLATE = 6;
const int TAG = 7;

uniform int kind = 0;
uniform float reveal : hint_range(0.0, 1.0) = 1.0;
uniform float progress : hint_range(0.0, 1.0) = 0.0;
uniform float ghost = -1.0;
uniform float playing = 1.0;
uniform float battery = -1.0;
uniform float hover = 0.0;
uniform float active = 0.0;
uniform float approach = 0.0;
uniform float ripple = 10.0;
uniform float enabled = 1.0;
uniform float emit = 0.0;
uniform float seed = 0.0;
uniform vec2 size_m = vec2(0.05, 0.017);
// CONE: projection from the face (apex, in the disc's local space) to the disc rim.
uniform vec3 apex = vec3(0.0, 0.0, -0.085);
uniform float apex_radius = 0.016;
uniform float base_radius = 0.112;
uniform vec4 accent : source_color = vec4(0.54, 0.93, 0.77, 1.0);
uniform vec4 secondary : source_color = vec4(0.36, 0.84, 1.0, 1.0);
uniform vec4 warning : source_color = vec4(1.0, 0.42, 0.38, 1.0);
uniform int mark_count = 0;
uniform float marks[16];

const vec3 GLASS = vec3(0.008, 0.022, 0.03);
const vec3 AMBER = vec3(1.0, 0.76, 0.36);

varying float cone_v;
varying float cone_u;

float line(float d, float width, float aa) {
	return 1.0 - smoothstep(width - aa, width + aa, abs(d));
}

float glow(float d, float radius) {
	return exp(-abs(d) / max(radius, 1e-4));
}

// Clockwise angle from twelve o'clock (+Y), 0..1.
float clock_angle(vec2 p) {
	return fract(atan(p.x, p.y) / TAU + 1.0);
}

float hash(float n) {
	return fract(sin(n * 91.3458) * 47453.5453);
}

float hash2(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

// Projector flicker shared by every projected element: a steady hum with irregular dips, much
// stronger while the projection boots.
float flicker(float boot) {
	float t = TIME;
	float hum = 0.9 + 0.06 * sin(t * 47.0) + 0.04 * sin(t * 13.0 + 1.3);
	float dip = step(0.93, hash(floor(t * 14.0))) * 0.22;
	float stutter = (1.0 - boot) * step(0.45, hash(floor(t * 40.0) + 7.0));
	return clamp(hum - dip - stutter * 0.7, 0.0, 1.0);
}

// Horizontal interference band sweeping through the projection now and then.
float interference(float y) {
	float t = TIME;
	float live = step(0.55, hash(floor(t * 0.7)));
	float position = fract(t * 0.7) * 1.6 - 0.3;
	return live * (1.0 - smoothstep(0.0, 0.035, abs(y - position)));
}

void add(inout vec4 c, vec3 color, float amount) {
	amount = clamp(amount, 0.0, 1.0);
	c.rgb = mix(c.rgb, color, amount);
	c.a = c.a + amount * (1.0 - c.a);
}

vec4 face(vec2 uv) {
	vec2 p = (uv - 0.5) * 2.0;
	p.y = -p.y;
	float r = length(p);
	float aa = fwidth(r) * 1.2;
	float a = clock_angle(p);
	float t = TIME;
	float boot = smoothstep(a - 0.05, a, reveal * 1.25 - 0.1);
	float flick = reveal < 1.0 ? 0.75 + 0.25 * step(0.4, hash(floor(t * 30.0))) : 1.0;
	vec4 c = vec4(0.0);
	float plate = 1.0 - smoothstep(0.95 - aa, 0.95 + aa, r);
	add(c, GLASS * 0.8, plate * 0.72 * reveal);
	float disc = 1.0 - smoothstep(0.66 - aa, 0.66 + aa, r);
	vec2 h = p * 9.0;
	h.x *= 1.1547; h.y += mod(floor(h.x), 2.0) * 0.5;
	vec2 cell = abs(fract(h) - 0.5);
	float lattice = smoothstep(0.43, 0.5, max(cell.x * 1.5 + cell.y, cell.y * 2.0));
	add(c, GLASS + secondary.rgb * 0.06 * (1.0 - r), disc * 0.85 * reveal);
	add(c, secondary.rgb, line(r - 0.66, 0.006, aa) * 0.35 * reveal);
	add(c, secondary.rgb, disc * lattice * 0.07 * reveal * (1.0 - r));
	float behind = fract(fract(t * 0.25) - a);
	add(c, accent.rgb, disc * playing * pow(1.0 - behind, 10.0) * 0.18 * reveal * (1.0 - emit));
	if (battery >= 0.0) {
		float along = (a - 0.38) / 0.24;
		float on = step(0.0, along) * step(along, 1.0);
		float ring = line(r - 0.58, 0.012, aa);
		vec3 tone = battery < 0.2 ? warning.rgb : accent.rgb;
		add(c, secondary.rgb, ring * on * 0.25 * reveal);
		add(c, tone, ring * on * step(1.0 - along, battery) * 0.95 * reveal);
	}
	float track = line(r - 0.74, 0.035, aa);
	add(c, secondary.rgb * 0.5, track * 0.3 * boot);
	vec3 fill = mix(secondary.rgb, accent.rgb, a);
	add(c, fill, step(a, progress) * track * boot);
	add(c, fill, glow(r - 0.74, 0.05) * step(a, progress) * 0.35 * boot);
	vec2 head = vec2(sin(progress * TAU), cos(progress * TAU)) * 0.74;
	float hd = length(p - head);
	add(c, vec3(1.0), (1.0 - smoothstep(0.045 - aa, 0.045 + aa, hd)) * boot);
	add(c, accent.rgb, glow(hd, 0.06) * 0.6 * boot);
	for (int i = 0; i < 16; i++) {
		if (i >= mark_count) break;
		float d = abs(fract(a - marks[i] + 0.5) - 0.5) * TAU * r;
		add(c, AMBER, (1.0 - smoothstep(0.012, 0.012 + aa, d)) * line(r - 0.74, 0.06, aa) * boot);
	}
	float minute = abs(fract(a * 60.0 + 0.5) - 0.5) / 60.0 * TAU * r;
	float major = step(abs(fract(a * 12.0 + 0.5) - 0.5), 0.02);
	float tick_band = step(0.83 - major * 0.03, r) * step(r, 0.89);
	add(c, mix(secondary.rgb, vec3(1.0), major), (1.0 - smoothstep(0.006, 0.006 + aa, minute)) * tick_band * (0.35 + major * 0.5) * boot);
	add(c, accent.rgb, line(r - 0.93, 0.008, aa) * (0.7 + hover * 0.3) * boot);
	add(c, accent.rgb, glow(r - 0.93, 0.03) * (0.15 + hover * 0.35 + 0.1 * sin(t * 5.0) * hover) * boot);
	// Emitter: while projecting, the rim of the glass lights and rings pulse outward, leaving the
	// middle dark enough for the time to stay readable.
	if (emit > 0.0) {
		float pulse = fract(t * 1.2);
		add(c, secondary.rgb, disc * smoothstep(0.35, 0.66, r) * 0.45 * emit * flicker(1.0));
		add(c, vec3(1.0), line(r - (0.4 + pulse * 0.26), 0.015, aa) * (1.0 - pulse) * 0.5 * emit);
	}
	float wave = ripple * 2.2;
	add(c, vec3(1.0), line(r - wave, 0.02, aa) * max(0.0, 1.0 - ripple * 2.5));
	c.a *= flick * step(r, 1.0);
	return c;
}

// Timeline ring on the disc: UV.x runs clockwise from twelve o'clock, UV.y inner to outer.
vec4 ring(vec2 uv) {
	float x = uv.x;
	float y = (uv.y - 0.5) * 2.0;
	float aa = fwidth(y) * 1.2;
	float ax = fwidth(x) * 1.2;
	float t = TIME;
	vec4 c = vec4(0.0);
	float body = 1.0 - smoothstep(0.85, 1.0, abs(y));
	add(c, GLASS, body * 0.5);
	// The whole track must read as a ring even where nothing has played yet.
	add(c, secondary.rgb, glow(abs(y) - 0.9, 0.25) * (0.16 + hover * 0.3));
	float rails = line(abs(y) - 0.86, 0.04, aa);
	float pulse = pow(fract(x * 4.0 - t * 0.3 + seed), 18.0);
	add(c, mix(secondary.rgb, vec3(1.0), 0.25), rails * (0.6 + pulse * 0.4 + hover * 0.3));
	float grad = 1.0 - smoothstep(0.0012, 0.0012 + ax, abs(fract(x * 60.0 + 0.5) - 0.5) / 60.0);
	float major = 1.0 - smoothstep(0.0025, 0.0025 + ax, abs(fract(x * 4.0 + 0.5) - 0.5) / 4.0);
	add(c, secondary.rgb, grad * step(0.55, abs(y)) * step(abs(y), 0.78) * 0.3);
	add(c, vec3(1.0), major * step(0.45, abs(y)) * step(abs(y), 0.85) * 0.35);
	float core = line(y, 0.18, aa);
	add(c, secondary.rgb * 0.75, core * (0.45 + hover * 0.3));
	vec3 fill = mix(secondary.rgb, accent.rgb, x);
	add(c, fill, core * step(x, progress) * (0.85 + active * 0.15));
	add(c, fill, glow(y, 0.25) * step(x, progress) * 0.25);
	for (int i = 0; i < 16; i++) {
		if (i >= mark_count) break;
		add(c, AMBER, (1.0 - smoothstep(0.0012, 0.0012 + ax, abs(x - marks[i]))) * step(abs(y), 0.7) * 0.95);
	}
	if (ghost >= 0.0) {
		float dash = step(0.5, fract(y * 4.0 + t * 2.0));
		add(c, vec3(1.0), (1.0 - smoothstep(0.0012, 0.0012 + ax, abs(x - ghost))) * dash * 0.7);
	}
	// End caps mark where the video starts and ends.
	add(c, vec3(1.0), (1.0 - smoothstep(0.004, 0.004 + ax, min(x, 1.0 - x))) * 0.85);
	float hx = abs(x - progress);
	add(c, vec3(1.0), (1.0 - smoothstep(0.0018, 0.0018 + ax, hx)) * (1.0 - smoothstep(0.95, 1.0, abs(y))));
	add(c, accent.rgb, exp(-hx / (0.006 + active * 0.005)) * (0.5 + active * 0.4) * body);
	// Draws on clockwise with a bright leading edge.
	float open = 1.0 - smoothstep(reveal - 0.02, reveal, x);
	c.a *= open;
	add(c, vec3(1.0), (1.0 - smoothstep(0.0, 0.012, abs(x - reveal))) * (1.0 - step(0.995, reveal)) * body);
	c.a *= flicker(reveal);
	return c;
}

vec4 guide(vec2 uv) {
	float y = (uv.y - 0.5) * 2.0;
	float aa = fwidth(y) * 1.5;
	float dash = step(0.4, fract(uv.x * 160.0 - TIME * 0.6));
	vec4 c = vec4(0.0);
	add(c, mix(secondary.rgb, accent.rgb, active), line(y, 0.22, aa) * mix(dash * 0.35, 1.0, active));
	add(c, accent.rgb, glow(y, 0.6) * active * 0.35);
	c.a *= reveal;
	return c;
}

vec4 button(vec2 uv) {
	vec2 p = (uv - 0.5) * 2.0;
	p.y = -p.y;
	float r = length(p);
	float aa = fwidth(r) * 1.2;
	float a = clock_angle(p);
	float t = TIME;
	vec4 c = vec4(0.0);
	float lit = mix(0.35, 1.0, enabled);
	float disc = 1.0 - smoothstep(0.72 - aa, 0.72 + aa, r);
	add(c, GLASS + accent.rgb * 0.12 * hover, disc * (0.8 + hover * 0.1));
	float crescent = (1.0 - smoothstep(0.0, 0.05, abs(length(p - vec2(0.0, -0.22)) - 0.86))) * smoothstep(0.1, 0.5, p.y) * disc;
	add(c, vec3(1.0), crescent * 0.12);
	add(c, accent.rgb, disc * glow(r - 0.72, 0.2) * 0.12 * (1.0 + hover * 2.0) * enabled);
	float rim = line(r - 0.72, 0.022, aa);
	float shine = pow(0.5 + 0.5 * cos((a - fract(t * 0.2 + seed)) * TAU), 6.0);
	add(c, mix(secondary.rgb, accent.rgb, hover), rim * lit * (0.55 + 0.45 * shine + hover * 0.4));
	float seg = step(0.55, fract(a * 24.0 + t * (0.1 + hover * 0.6)));
	add(c, accent.rgb, line(r - 0.84, 0.012, aa) * seg * hover * 0.8);
	float closing = mix(1.0, 0.74, approach);
	add(c, vec3(1.0), line(r - closing, 0.018, aa) * step(0.01, approach) * (0.3 + approach * 0.6) * enabled);
	add(c, accent.rgb, disc * max(0.0, 1.0 - ripple * 5.0) * 0.6);
	add(c, vec3(1.0), line(r - (0.72 + ripple * 0.9), 0.02, aa) * max(0.0, 1.0 - ripple * 3.0));
	add(c, accent.rgb, line(r - 0.72, 0.06, aa) * active * 0.8);
	c.a *= reveal * step(r, 1.0) * flicker(reveal);
	return c;
}

// The light cone: bright silhouette edges, streaks, rising scan rings and motes, and flicker.
// seed > 0.5 draws the narrow, hot core beam inside it.
vec4 cone(vec3 normal, vec3 view) {
	float u = cone_u;
	float v = cone_v;   // 0 at the face, 1 at the disc
	float t = TIME;
	float edge = 1.0 - abs(dot(normalize(normal), normalize(view)));
	float drawn = 1.0 - smoothstep(reveal * 1.15 - 0.15, reveal * 1.15, v);
	vec4 c = vec4(0.0);
	if (seed > 0.5) {
		float hot = mix(1.0, 0.25, v);
		add(c, mix(secondary.rgb, vec3(1.0), 0.6), (0.25 + pow(1.0 - edge, 2.0) * 0.5) * hot);
		add(c, vec3(1.0), pow(fract(v * 4.0 - t * 2.2), 8.0) * 0.5 * hot);
		c.a *= drawn * flicker(reveal);
		return c;
	}
	float source = mix(1.0, 0.55, v);
	vec3 tint = mix(secondary.rgb, vec3(1.0), pow(edge, 8.0) * 0.6);
	add(c, tint, (0.1 + pow(edge, 2.5) * 0.75) * source);
	float streaks = pow(0.5 + 0.5 * cos((u * 28.0 + sin(t * 0.7 + u * 9.0) * 0.08) * TAU), 24.0);
	add(c, secondary.rgb, streaks * 0.28 * source);
	// Scan rings travelling up the beam.
	add(c, accent.rgb, pow(fract(v * 2.5 - t * 0.9), 14.0) * 0.6);
	// Fine scanlines and rising motes.
	add(c, secondary.rgb, (0.5 + 0.5 * sin(v * 90.0 - t * 18.0)) * 0.07);
	vec2 grid = vec2(u * 36.0, v * 8.0 - t * 1.4);
	vec2 id = floor(grid);
	vec2 local = fract(grid) - 0.5;
	float mote = step(0.84, hash2(id + seed)) * (1.0 - smoothstep(0.05, 0.14, length(local * vec2(1.0, 2.4))));
	add(c, vec3(1.0), mote * 0.9);
	add(c, vec3(1.0), interference(v) * 0.45);
	// Fade into the disc so the beam and the plate meet softly.
	c.a *= drawn * (1.0 - smoothstep(0.92, 1.0, v) * 0.5) * flicker(reveal);
	return c;
}

vec4 cursor(vec2 uv) {
	vec2 p = (uv - 0.5) * 2.0;
	float r = length(p);
	float aa = fwidth(r) * 1.2;
	vec4 c = vec4(0.0);
	float ring_r = mix(0.95, 0.35, approach);
	add(c, accent.rgb, line(r - ring_r, 0.06, aa) * (0.4 + approach * 0.6));
	add(c, vec3(1.0), (1.0 - smoothstep(0.16 - aa, 0.16 + aa, r)) * (0.5 + approach * 0.5));
	add(c, accent.rgb, glow(r, 0.25) * approach * 0.4);
	c.a *= reveal;
	return c;
}

// The disc the cone projects onto: graduated rings, a rotating segment ring and faint spokes.
// seed > 0.5 draws the sparse counter-rotating layer floating just below it.
vec4 plate(vec2 uv) {
	vec2 p = (uv - 0.5) * 2.0;
	p.y = -p.y;
	float r = length(p);
	float aa = fwidth(r) * 1.2;
	float a = clock_angle(p);
	float t = TIME;
	vec4 c = vec4(0.0);
	float grow = 1.0 - smoothstep(reveal - 0.04, reveal, r);
	if (seed > 0.5) {
		add(c, secondary.rgb, line(r - 0.9, 0.01, aa) * step(0.3, fract(a * 6.0 + t * 0.05)) * 0.55);
		add(c, accent.rgb, line(r - 0.8, 0.03, aa) * step(0.82, fract(a * 3.0 - t * 0.09)) * 0.7);
		add(c, secondary.rgb, line(r - 0.8, 0.006, aa) * 0.25);
	} else {
		// Clear in the middle so the beam stays visible through the disc.
		add(c, GLASS, (1.0 - smoothstep(0.96 - aa, 0.96 + aa, r)) * mix(0.06, 0.28, smoothstep(0.4, 0.95, r)));
		add(c, secondary.rgb, glow(r - 0.97, 0.04) * 0.25 + line(r - 0.97, 0.006, aa) * 0.7);
		float tick = 1.0 - smoothstep(0.004, 0.004 + aa, abs(fract(a * 72.0 + 0.5) - 0.5) / 72.0 * TAU * r);
		add(c, secondary.rgb, tick * step(0.9, r) * step(r, 0.95) * 0.5);
		add(c, accent.rgb, line(r - 0.52, 0.004, aa) * 0.3);
		add(c, secondary.rgb, line(r - 0.22, 0.006, aa) * 0.35);
		float spokes = 1.0 - smoothstep(0.002, 0.002 + aa, abs(fract(a * 24.0 + 0.5) - 0.5) / 24.0 * TAU * r);
		add(c, secondary.rgb, spokes * step(0.24, r) * step(r, 0.86) * 0.06);
		add(c, accent.rgb, line(r - 0.6, 0.012, aa) * step(0.7, fract(a * 2.0 + t * 0.1)) * 0.6);
	}
	add(c, vec3(1.0), line(r - reveal, 0.012, aa) * (1.0 - step(0.995, reveal)));
	add(c, secondary.rgb, interference(uv.y) * 0.12 * step(r, 0.97));
	c.a *= grow * step(r, 1.0) * flicker(reveal);
	return c;
}

vec4 tag(vec2 uv) {
	vec2 p = (uv - 0.5) * size_m;
	float radius = size_m.y * 0.45;
	vec2 q = abs(p) - (size_m * 0.5 - vec2(radius + 0.0008));
	float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
	float aa = fwidth(d) * 1.2;
	vec4 c = vec4(0.0);
	add(c, GLASS, (1.0 - smoothstep(-aa, aa, d)) * 0.85);
	add(c, accent.rgb, line(d, 0.00035, aa) * 0.95);
	add(c, accent.rgb, glow(max(d, 0.0), 0.0012) * 0.35 * step(0.0, d));
	c.a *= reveal;
	return c;
}

void vertex() {
	if (kind == CONE) {
		// VERTEX carries (cos, sin, v) of a unit cone; bend it between the face and the disc.
		vec3 around = vec3(VERTEX.x, VERTEX.y, 0.0);
		cone_v = VERTEX.z;
		cone_u = fract(atan(VERTEX.x, VERTEX.y) / TAU + 1.0);
		vec3 bottom = apex + around * apex_radius;
		vec3 top = around * base_radius;
		VERTEX = mix(bottom, top, cone_v);
		vec3 along = normalize(top - bottom);
		NORMAL = normalize(around - along * dot(around, along));
	}
}

void fragment() {
	vec4 c;
	if (kind == FACE) c = face(UV);
	else if (kind == RING) c = ring(UV);
	else if (kind == BUTTON) c = button(UV);
	else if (kind == GUIDE) c = guide(UV);
	else if (kind == CONE) c = cone(NORMAL, VIEW);
	else if (kind == CURSOR) c = cursor(UV);
	else if (kind == TAG) c = tag(UV);
	else c = plate(UV);
	ALBEDO = c.a > 0.0001 ? c.rgb : vec3(0.0);
	ALPHA = clamp(c.a, 0.0, 1.0);
}
