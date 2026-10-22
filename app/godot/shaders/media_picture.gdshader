shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix, fog_disabled;

uniform sampler2D picture : source_color, filter_linear_mipmap, repeat_disable;
uniform vec2 image_size = vec2(1.0);
uniform vec2 surface_size = vec2(1.0);
uniform bool hovered = false;

void fragment() {
	vec2 point = (UV - vec2(0.5)) * surface_size;
	vec2 size = image_size * (hovered ? 1.025 : 1.0);
	vec2 local = point + (hovered ? vec2(0.0, 0.002) : vec2(0.0));
	vec2 uv = local / size + vec2(0.5);
	vec2 inset = size * 0.5 - abs(local);
	float edge = max(fwidth(min(inset.x, inset.y)), 0.0003);
	float coverage = smoothstep(-edge, edge, min(inset.x, inset.y));
	vec4 color = texture(picture, clamp(uv, vec2(0.0), vec2(1.0)));
	float ink = color.a * coverage;
	float shadow = 0.0;
	if (hovered) {
		// An analytic contact shadow in this same quad: one image sample, no blur or light pass.
		vec2 q = abs(point - vec2(0.002, 0.004)) - (size * 0.5 - vec2(0.003));
		float distance = length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - 0.003;
		shadow = 0.58 * (1.0 - smoothstep(-0.001, 0.006, distance));
	}
	float alpha = ink + shadow * (1.0 - ink);
	ALBEDO = color.rgb * (hovered ? 1.04 : 1.0) * ink / max(alpha, 0.0001);
	ALPHA = alpha;
}
