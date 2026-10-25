shader_type spatial;
// The scenery sky while the video is on a compositor layer. A transparent eye buffer is needed then
// (blending writes correct alpha only for transparent viewports) and Godot draws no sky for it, so
// this camera-centred sphere draws the same panorama, or the plain background colour.
render_mode unshaded, cull_front, shadows_disabled, fog_disabled;

// Match PanoramaSkyMaterial's base-level bilinear sampling. Mipmap selection
// across wrapped longitude pulls distant bright sky into the seam and poles.
uniform sampler2D panorama : source_color, filter_linear, repeat_enable;
uniform bool has_panorama = false;
uniform float energy_multiplier = 1.0;
uniform vec3 background : source_color = vec3(0.035, 0.045, 0.06);
uniform mat3 orientation = mat3(1.0); // inverse of Environment.sky_rotation: world to sky space
varying vec3 world_direction;

// Keep the same mapping as Godot 4.7.2 GLES3's PANORAMA_COORDS. Exact acos/atan
// differ from its approximations by up to ~0.5 degrees, making scenery jump
// whenever menu composition switches between the sky and this backdrop.
// Adapted from drivers/gles3/shaders/sky.glsl (Godot MIT license;
// see third_party/player-licenses/godot-sky.txt).
float sky_acos(float value) {
	float x = clamp(abs(value), 0.0, 1.0);
	float angle = (-0.156583 * x + PI * 0.5) * sqrt(1.0 - x);
	return value >= 0.0 ? angle : PI - angle;
}

float sky_atan2(float y, float x) {
	float longest = max(abs(x), abs(y));
	// Longitude is undefined at the exact pole; avoid 0/0.
	if (longest == 0.0) { return 0.0; }
	float a = min(abs(x), abs(y)) / longest;
	float s = a * a;
	float angle = ((0.0872929 * s - 0.301895) * s + 1.0) * a;
	angle = abs(y) > abs(x) ? PI * 0.5 - angle : angle;
	angle = x < 0.0 ? PI - angle : angle;
	return y < 0.0 ? -angle : angle;
}

void vertex() {
	world_direction = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz - CAMERA_POSITION_WORLD;
}

void fragment() {
	if (!has_panorama) {
		ALBEDO = background;
	} else {
		// Match the engine's approximation as well as its axis convention.
		vec3 d = normalize(orientation * world_direction);
		float u = sky_atan2(d.x, -d.z);
		if (u < 0.0) { u += 2.0 * PI; }
		vec2 uv = vec2(u, sky_acos(d.y)) / vec2(2.0 * PI, PI);
		ALBEDO = textureLod(panorama, uv, 0.0).rgb * energy_multiplier;
	}
}
