shader_type spatial;
// The scenery sky while the video is on a compositor layer. A transparent eye buffer is needed then
// (blending writes correct alpha only for transparent viewports) and Godot draws no sky for it, so
// this camera-centred sphere draws the same panorama, or the plain background colour.
render_mode unshaded, cull_front, shadows_disabled, fog_disabled;

uniform sampler2D panorama : source_color, filter_linear_mipmap, repeat_enable;
uniform bool has_panorama = false;
uniform vec3 background : source_color = vec3(0.035, 0.045, 0.06);
uniform mat3 orientation = mat3(1.0); // inverse of Environment.sky_rotation: world to sky space
varying vec3 world_direction;

void vertex() {
	world_direction = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz - CAMERA_POSITION_WORLD;
}

void fragment() {
	if (!has_panorama) {
		ALBEDO = background;
	} else {
		// Godot's GLES3 sky panorama coordinates (drivers/gles3/shaders/sky.glsl) for the eye
		// direction in sky space: atan(x, -z) wrapped to [0, 2pi), acos(y).
		vec3 d = normalize(orientation * world_direction);
		float u = atan(d.x, -d.z);
		if (u < 0.0) { u += 2.0 * PI; }
		vec2 uv = vec2(u, acos(clamp(d.y, -1.0, 1.0))) / vec2(2.0 * PI, PI);
		ALBEDO = texture(panorama, uv).rgb;
	}
}
