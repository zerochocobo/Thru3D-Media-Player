shader_type spatial;
render_mode unshaded, cull_back, depth_draw_opaque;

uniform vec3 tint : source_color = vec3(1.0);
uniform float cinema_light_mix : hint_range(0.0, 1.0) = 1.0;

void fragment() {
	ALBEDO = tint * cinema_light_mix;
}
