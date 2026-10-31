shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;
uniform vec2 surface_size = vec2(3.8, 2.14);
uniform float presentation_opacity = 1.0;
uniform float feather_metres = 0.07;
uniform float reveal_progress = -1.0;
uniform float flow_time = -1.0;
uniform bool portrait_loading = false;
#include "res://shaders/photo_reveal.gdshaderinc"

void fragment() {
	vec2 fade = smoothstep(vec2(0.0), vec2(feather_metres) / surface_size, min(UV, vec2(1.0) - UV));
	float edge = fade.x * fade.y;
	float clock = flow_time >= 0.0 ? flow_time : TIME;
	if (portrait_loading) {
		// A compact indicator beneath the subject, with no picture-sized frosted surface.
		vec2 point = (UV - vec2(0.5)) * surface_size;
		point.y -= max(0.0, surface_size.y * 0.5 - 0.16);
		float dots = 0.0;
		for (int i = 0; i < 3; i++) {
			float pulse = 0.45 + 0.3 * sin(clock * 4.0 - float(i) * 0.9);
			float distance = length(point - vec2((float(i) - 1.0) * 0.085, 0.0));
			dots = max(dots, (1.0 - smoothstep(0.018, 0.026, distance)) * pulse);
		}
		ALBEDO = vec3(0.8, 0.94, 0.98);
		ALPHA = dots * presentation_opacity;
	} else {
		vec4 glass = photo_loading_glass(UV, surface_size, clock, reveal_progress);
		ALBEDO = glass.rgb;
		ALPHA = edge * glass.a * presentation_opacity;
	}
}
