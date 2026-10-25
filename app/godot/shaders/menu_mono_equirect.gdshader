shader_type canvas_item;
render_mode unshaded, blend_disabled;
uniform sampler2D menu_texture : source_color, filter_linear, repeat_disable;
// Centre and extent of the centre-eye perspective capture at z=-1.
uniform vec4 capture_rect;
// Full longitude span, upper latitude, positive lower latitude (Godot convention).
uniform vec3 angles;
void fragment() {
    float longitude = (UV.x - 0.5) * angles.x;
    float latitude = mix(angles.y, -angles.z, UV.y);
    vec2 tangent = vec2(tan(longitude), tan(latitude) / cos(longitude));
    vec2 sample_uv = (tangent - capture_rect.xy) / capture_rect.zw;
    sample_uv = vec2(0.5 + sample_uv.x, 0.5 - sample_uv.y);
    if (any(lessThan(sample_uv, vec2(0.0))) || any(greaterThan(sample_uv, vec2(1.0)))) {
        COLOR = vec4(0.0);
    } else {
        COLOR = texture(menu_texture, sample_uv);
    }
}
