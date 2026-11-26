shader_type spatial;
// A library thumbnail with the same rounded corners as the controls around it.
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;

uniform sampler2D picture : source_color, filter_linear_mipmap;
uniform vec2 surface_size = vec2(1.0);
uniform float corner_radius = 0.016;

void fragment() {
    float radius = min(corner_radius, min(surface_size.x, surface_size.y) * 0.5);
    vec2 q = abs((UV - vec2(0.5)) * surface_size) - (surface_size * 0.5 - vec2(radius));
    float distance = length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
    float edge = max(fwidth(distance), 0.0003);
    vec4 texel = texture(picture, UV);
    ALBEDO = texel.rgb;
    ALPHA = texel.a * (1.0 - smoothstep(-edge, edge, distance));
}
