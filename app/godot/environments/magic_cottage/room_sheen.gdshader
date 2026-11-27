shader_type spatial;
// Glass, brass and glaze in the baked attic: unshaded like the room, with a rim and a small glint
// from a fixed hearth-side key, so they read as polished without any real-time light.
render_mode unshaded, cull_disabled, shadows_disabled;
uniform float lift = 2.0;
uniform vec3 room_light = vec3(1.0);
void fragment() {
	vec3 base = COLOR.rgb * lift;
	float facing = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float rim = pow(1.0 - facing, 3.0);
	vec3 key = normalize((VIEW_MATRIX * vec4(0.55, 0.70, 0.45, 0.0)).xyz);
	float glint = pow(clamp(dot(reflect(-VIEW, NORMAL), key), 0.0, 1.0), 24.0);
	float body = clamp(length(base), 0.15, 1.0);
	ALBEDO = (base * (1.0 + 0.25 * rim) + vec3(1.0, 0.86, 0.62) * body * (0.22 * rim + 0.35 * glint)) * room_light;
}
