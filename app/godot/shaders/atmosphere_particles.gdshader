shader_type spatial;
// One layer of an atmosphere theme (docs/ATMOSPHERE_THEMES_PLAN_20261116_CN.md): rain, snow,
// leaves, petals, fireflies or bubbles. Every particle's place comes from its instance's random
// numbers and the clock, so nothing is simulated per frame. The particles fill a box that follows
// the head and wrap inside it, which looks fixed in the world. Premultiplied colour, like the
// screen halo, so the compositor layers beneath the eye buffer keep correct alpha.
render_mode unshaded, blend_premul_alpha, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled, world_vertex_coords;

const int DOT = 0;
const int STREAK = 1;
const int LEAF = 2;
const int PETAL = 3;
const int BUBBLE = 4;

// The box's centre and the head, the same for both eyes: each eye wrapping about itself would
// tear the pair apart. The box sits on the floor, so its centre is not always the head.
uniform vec3 centre;
uniform vec3 head;
uniform vec3 box = vec3(8.0, 6.0, 8.0);
uniform float clock = 0.0;
uniform vec3 velocity = vec3(0.0, -1.0, 0.0);
uniform vec3 sway = vec3(0.0);
uniform float sway_rate = 1.0;
// Quad width and height in metres; `spread` is how much smaller the smallest particle is.
uniform vec2 size = vec2(0.03);
uniform float spread = 0.4;
uniform int shape = 0;
uniform float tumble = 0.0;
uniform float pulse = 0.0;
// 1 adds light without hiding what is behind (fireflies); 0 covers it.
uniform float glow = 0.0;
uniform vec4 tint_a : source_color = vec4(1.0);
uniform vec4 tint_b : source_color = vec4(1.0);
uniform float opacity = 1.0;
// Nothing drifts through the menus held in front of the viewer.
uniform vec2 near_fade = vec2(1.2, 2.0);
uniform float floor_y = -100.0;
// The flat picture being watched: world to its plane (x, y across it, z out of it) and its half
// size. A particle the eye would see across the picture fades out, in front of it or behind.
uniform mat4 screen_inverse = mat4(1.0);
uniform vec2 screen_half = vec2(0.0);
uniform float screen_margin = 0.15;
// Where the eye buffer is see-through (passthrough, or a panorama on its compositor layer) the
// compositor takes the stored colour as display-referred.
uniform bool display_referred = false;

varying float fade;
varying float blend;

void vertex() {
	vec4 seed = INSTANCE_CUSTOM;
	float phase = seed.w * 6.2831853;
	vec3 drift = velocity * (0.75 + 0.5 * seed.w) * clock;
	vec3 offset = (fract((seed.xyz * box + drift - centre) / box) - 0.5) * box;
	vec3 wobble = sway * vec3(
		sin(clock * sway_rate * (0.7 + 0.6 * seed.x) + phase),
		sin(clock * sway_rate * 0.63 * (0.7 + 0.6 * seed.y) + phase * 1.7),
		cos(clock * sway_rate * 0.81 * (0.7 + 0.6 * seed.z) + phase * 2.3));
	vec3 place = centre + offset + wobble;

	// The wrap happens where nothing is drawn: at the box's walls, floor and ceiling.
	vec3 reach = abs(offset) / (box * 0.5);
	fade = 1.0 - smoothstep(0.85, 1.0, max(length(reach.xz), reach.y));
	fade *= smoothstep(near_fade.x, near_fade.y, length(place - head));
	fade *= smoothstep(floor_y, floor_y + 0.3, place.y);
	if (pulse > 0.0) {
		float beat = sin(clock * pulse * (0.6 + 0.8 * seed.y) + phase * 3.1);
		fade *= smoothstep(-0.6, 0.6, beat);
	}

	vec2 extent = size * (1.0 - spread * seed.y);
	if (screen_half.x > 0.0) {
		vec3 eye = (screen_inverse * vec4(CAMERA_POSITION_WORLD + (INV_VIEW_MATRIX * vec4(EYE_OFFSET, 0.0)).xyz, 1.0)).xyz;
		vec3 ray = (screen_inverse * vec4(place, 1.0)).xyz - eye;
		if (abs(ray.z) > 0.00001) {
			float along = -eye.z / ray.z;
			if (along > 0.0) {
				vec2 outside = abs(eye.xy + ray.xy * along) - screen_half;
				float pad = max(extent.x, extent.y) * 0.5;
				fade *= smoothstep(pad, pad + screen_margin, max(outside.x, outside.y));
			}
		}
	}
	fade *= opacity;
	blend = seed.z;

	vec3 right = INV_VIEW_MATRIX[0].xyz;
	vec3 up = INV_VIEW_MATRIX[1].xyz;
	// A faded particle collapses, so it costs no fragments.
	if (fade <= 0.002) { extent = vec2(0.0); }
	vec2 corner = VERTEX.xy * extent;
	if (shape == STREAK) {
		// A streak lies along its fall and turns about that line to face the eye.
		up = normalize(velocity);
		vec3 side = cross(up, place - CAMERA_POSITION_WORLD);
		right = dot(side, side) > 0.000001 ? normalize(side) : right;
	} else if (tumble > 0.0) {
		// Spinning in the quad's plane and squashing its width reads as a leaf turning over.
		float angle = clock * tumble * (0.6 + 0.8 * seed.x) + phase;
		float turn = cos(clock * tumble * 1.3 * (0.6 + 0.8 * seed.z) + phase * 1.9);
		corner.x *= sign(turn) * max(abs(turn), 0.18);
		corner = vec2(corner.x * cos(angle) - corner.y * sin(angle), corner.x * sin(angle) + corner.y * cos(angle));
	}
	VERTEX = place + right * corner.x + up * corner.y;
}

// Distance to a pointed oval standing upright, 1 tall: negative inside.
float lens(vec2 point, float half_width) {
	float shift = (1.0 - half_width * half_width) / (2.0 * half_width);
	return length(vec2(abs(point.x) + shift, point.y)) - (half_width + shift);
}

void fragment() {
	vec2 point = UV * 2.0 - 1.0;
	float radius = length(point);
	vec4 tint = mix(tint_a, tint_b, blend);
	vec3 colour = tint.rgb;
	float cover = 0.0;
	if (shape == DOT) {
		// A soft disc; a glowing one is a small core in a wide halo.
		cover = glow > 0.0 ? exp(-radius * radius * 9.0) * (1.0 - smoothstep(0.8, 1.0, radius)) + (1.0 - smoothstep(0.0, 0.22, radius)) : 1.0 - smoothstep(0.3, 1.0, radius);
		cover = min(cover, 1.0);
	} else if (shape == STREAK) {
		// Bright at the leading end, thinning out behind it.
		cover = (1.0 - smoothstep(0.1, 1.0, abs(point.x))) * smoothstep(-1.0, 0.6, point.y) * (1.0 - smoothstep(0.75, 1.0, point.y));
	} else if (shape == LEAF) {
		cover = 1.0 - smoothstep(-0.10, 0.0, lens(point, 0.52));
		colour *= 0.72 + 0.28 * smoothstep(0.0, 0.10, abs(point.x));
	} else if (shape == PETAL) {
		cover = 1.0 - smoothstep(-0.12, 0.0, lens(point, 0.66));
		cover *= smoothstep(0.16, 0.28, length(point - vec2(0.0, 1.0)));
		colour = mix(vec3(1.0), colour, smoothstep(-1.0, 0.3, point.y));
	} else {
		// A thin rim with a small highlight: mostly see-through.
		cover = (1.0 - smoothstep(0.88, 1.0, radius)) * (0.14 + 0.86 * smoothstep(0.45, 0.88, radius));
		cover += (1.0 - smoothstep(0.0, 0.26, length(point - vec2(-0.36, 0.40)))) * 0.8;
		cover = min(cover, 1.0);
	}
	float alpha = cover * tint.a * fade;
	if (display_referred) {
		colour = mix(colour * 12.92, 1.055 * pow(colour, vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), colour));
	}
	ALBEDO = colour * alpha;
	ALPHA = alpha * (1.0 - glow);
}
