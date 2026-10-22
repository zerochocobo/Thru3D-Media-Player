shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, fog_disabled;
uniform sampler2D picture : source_color, filter_linear;
uniform sampler2D upcoming : source_color, filter_linear;
uniform float transition = 0.0;
uniform vec2 surface_size = vec2(1.0);
uniform float corner_radius = 0.028;
vec2 cover_uv(vec2 uv, ivec2 pixels) {
    float image_aspect = float(pixels.x) / max(1.0, float(pixels.y));
    float panel_aspect = surface_size.x / surface_size.y;
    vec2 scale = vec2(min(1.0, panel_aspect / image_aspect), min(1.0, image_aspect / panel_aspect));
    return (uv - vec2(0.5)) * scale + vec2(0.5);
}
void fragment() {
    vec3 first = texture(picture, cover_uv(UV, textureSize(picture, 0))).rgb;
    vec3 color = first;
    // The default still image needs one sample. Only an active fade reads both.
    if (transition > 0.0) {
        vec3 second = texture(upcoming, cover_uv(UV, textureSize(upcoming, 0))).rgb;
        color = mix(first, second, transition);
    }
	float shade = mix(0.16, 0.272, smoothstep(0.1, 0.9, UV.x));
    shade *= mix(1.0, 0.42, smoothstep(0.45, 1.0, UV.y));
    ALBEDO = color * shade;
    vec2 q = abs((UV - vec2(0.5)) * surface_size) - (surface_size * 0.5 - vec2(corner_radius));
    float distance = length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - corner_radius;
    ALPHA = 1.0 - smoothstep(-0.001, 0.001, distance);
}
