shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled;
uniform float room_light = 1.0;

void fragment() {
	float bevel = .66 + .34 * abs(dot(normalize(NORMAL), normalize(vec3(-.32, .45, .83))));
	ALBEDO = COLOR.rgb * bevel;
	ALBEDO *= room_light;
}
