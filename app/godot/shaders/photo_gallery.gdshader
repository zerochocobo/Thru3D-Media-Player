shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;
uniform sampler2D picture : source_color, filter_linear_mipmap, repeat_disable;
uniform bool has_picture = false;
uniform bool waiting_for_full = false;
uniform vec2 surface_size = vec2(1.5, 1.05);
uniform float flow_time = -1.0;
uniform vec4 crop_rect = vec4(0.0, 0.0, 1.0, 1.0);
uniform vec4 eye_rect = vec4(0.0, 0.0, 1.0, 1.0);
uniform int geometry = 0;
uniform float brightness = 1.0;
uniform float opacity = 1.0;
uniform vec2 edge_feather = vec2(0.0);
#include "res://shaders/photo_reveal.gdshaderinc"
void fragment() {
	vec2 p = crop_rect.xy + UV * crop_rect.zw;
	if (geometry > 0) {
		vec3 ray = normalize(vec3((p.x - 0.5) * 1.5, (0.5 - p.y) * 1.125, -1.0));
		if (geometry == 2) {
			float angle = acos(clamp(-ray.z, -1.0, 1.0));
			vec2 radial = length(ray.xy) > 0.0001 ? normalize(ray.xy) : vec2(0.0);
			p = vec2(0.5) + radial * vec2(1.0, -1.0) * angle / 3.14159265;
		} else {
			p = vec2(0.5 + atan(ray.x, -ray.z) / (geometry == 3 ? 6.2831853 : 3.14159265),
				0.5 - asin(ray.y) / 3.14159265);
		}
	}
	if (has_picture && !waiting_for_full) {
		vec4 color = texture(picture, eye_rect.xy + p * eye_rect.zw);
		ALBEDO = color.rgb * brightness;
		ALPHA = color.a * opacity;
	} else {
		vec4 glass = photo_loading_glass(UV, surface_size, flow_time >= 0.0 ? flow_time : TIME, -1.0);
		ALBEDO = glass.rgb;
		ALPHA = glass.a * opacity * mix(0.4, 1.0, brightness);
	}
	if (any(greaterThan(edge_feather, vec2(0.0)))) {
		vec2 fade = smoothstep(vec2(0.0), max(edge_feather, vec2(0.00001)), min(UV, vec2(1.0) - UV));
		ALPHA *= fade.x * fade.y;
	}
}
