// All coordinates remain per-eye. Cropping happens before packing, rotation and AI masks.
uniform bool pip_enabled = false;
uniform vec2 pip_edge_feather = vec2(0.0);
uniform vec2 pip_center = vec2(0.5);
uniform vec2 pip_span = vec2(0.333333);
uniform vec3 pip_forward = vec3(0.0, 0.0, -1.0);
uniform vec3 pip_right = vec3(1.0, 0.0, 0.0);
uniform vec3 pip_up = vec3(0.0, 1.0, 0.0);
uniform vec2 pip_tangent = vec2(0.57735, 0.32476);

vec3 pip_direction(vec2 uv, vec3 original) {
	if (!pip_enabled || video_geometry == 0) { return original; }
	vec2 p = (uv - vec2(0.5)) * 2.0 * pip_tangent;
	return pip_forward + pip_right * p.x - pip_up * p.y;
}

vec2 pip_uv(vec2 uv) {
	return pip_enabled && video_geometry == 0 ? pip_center + (uv - vec2(0.5)) * pip_span : uv;
}

bool pip_outside(vec3 d) {
	return pip_enabled && ((video_geometry == 1 && d.z > 0.0) || outside_lens(d));
}
