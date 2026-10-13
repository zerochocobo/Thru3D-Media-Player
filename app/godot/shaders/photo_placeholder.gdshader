shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;
uniform vec2 surface_size = vec2(3.8, 2.14);
uniform float presentation_opacity = 1.0;
uniform float feather_metres = 0.07;
uniform float reveal_progress = -1.0;
uniform float flow_time = -1.0;
#include "res://shaders/photo_reveal.gdshaderinc"

void fragment() {
	vec2 fade = smoothstep(vec2(0.0), vec2(feather_metres) / surface_size, min(UV, vec2(1.0) - UV));
	float edge = fade.x * fade.y;
	float clock = flow_time >= 0.0 ? flow_time : TIME;
	vec4 glass = photo_loading_glass(UV, surface_size, clock, reveal_progress);
	ALBEDO = glass.rgb;
	ALPHA = edge * glass.a * presentation_opacity;
}
