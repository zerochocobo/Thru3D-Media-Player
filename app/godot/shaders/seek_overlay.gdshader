shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, depth_test_disabled;
uniform vec4 tint : source_color = vec4(0.025, 0.035, 0.045, 0.78);
void fragment() {
    vec2 half_size = vec2(0.335, 0.0675);
    float radius = 0.018;
    vec2 q = abs((UV - 0.5) * half_size * 2.0) - half_size + radius;
    float d = length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
    float aa = max(fwidth(d), 0.00001);
    ALBEDO = tint.rgb;
    ALPHA = tint.a * (1.0 - smoothstep(-aa, aa, d));
}
