shader_type spatial;
render_mode unshaded, cull_back, depth_draw_opaque;
uniform int backdrop = 0;
void fragment() {
	vec3 base = backdrop == 2 ? vec3(0.56,0.59,0.63) : (backdrop == 1 ? vec3(0.075,0.115,0.16) : vec3(0.008,0.012,0.025));
	float horizon = exp(-abs(UV.y-0.5)*30.0) * 0.025;
	vec2 cell = floor(UV*vec2(340.0,170.0));
	float seed = fract(sin(dot(cell,vec2(127.1,311.7)))*43758.5453);
	vec2 f = fract(UV*vec2(340.0,170.0))-0.5;
	float star = (1.0-smoothstep(0.035,0.12,length(f))) * step(0.993,seed) * step(0.5,UV.y);
	ALBEDO = base + vec3(horizon) + (backdrop == 0 ? vec3(star*0.28) : vec3(0.0));
}
