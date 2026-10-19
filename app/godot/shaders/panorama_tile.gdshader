shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, depth_test_disabled, blend_mix, fog_disabled;
uniform sampler2D tile_texture : source_color, filter_linear_mipmap, repeat_disable;
uniform float opacity = 1.0;
uniform bool detail_projection = false;
uniform vec2 full_size = vec2(1.0);
uniform vec4 core_rect = vec4(0.0);
uniform vec4 decoded_rect = vec4(0.0, 0.0, 1.0, 1.0);
uniform vec3 detail_forward = vec3(0.0, 0.0, -1.0);
uniform vec3 detail_right = vec3(1.0, 0.0, 0.0);
uniform vec3 detail_up = vec3(0.0, 1.0, 0.0);
uniform float content_zoom = 1.0;
void fragment() {
    vec2 uv = UV;
    if (detail_projection) {
        vec2 p = (UV - vec2(0.5)) * vec2(0.8, -0.5) / (1.4 * content_zoom);
        vec3 d = normalize(detail_forward + detail_right * p.x + detail_up * p.y);
        vec2 pixel = vec2(atan(d.x, -d.z) / (2.0 * PI) + 0.5, 0.5 - asin(clamp(d.y, -1.0, 1.0)) / PI) * full_size;
        if (any(lessThan(pixel, core_rect.xy)) || any(greaterThanEqual(pixel, core_rect.xy + core_rect.zw))) { discard; }
        uv = (pixel - decoded_rect.xy) / decoded_rect.zw;
    }
    vec4 color = texture(tile_texture, uv);
    ALBEDO = color.rgb;
    ALPHA = color.a * opacity;
}
