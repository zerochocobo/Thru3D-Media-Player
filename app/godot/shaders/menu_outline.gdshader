shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;

uniform vec4 surface_color : source_color = vec4(0.72, 0.79, 0.82, 0.85);
uniform vec2 surface_size = vec2(1.0);
uniform float corner_radius = 0.012;
uniform bool hovered = false;

void fragment() {
	float radius = min(corner_radius, min(surface_size.x, surface_size.y) * 0.5);
	vec2 q = abs((UV - vec2(0.5)) * surface_size) - (surface_size * 0.5 - vec2(radius));
	float distance = length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
	float edge = max(fwidth(distance), 0.0003);
	ALBEDO = hovered ? vec3(0.38, 0.94, 0.73) : surface_color.rgb;
	float stroke = hovered ? 0.003 : 0.002;
	// Inside the existing hit area, with a transparent centre even in XR captures.
	ALPHA = surface_color.a * (1.0 - smoothstep(-edge, edge, distance))
		* smoothstep(-stroke - edge, -stroke + edge, distance);
}
