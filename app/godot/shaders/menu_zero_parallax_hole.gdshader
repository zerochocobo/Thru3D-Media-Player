shader_type spatial;
// Same angular footprint as the mono capture. Text colour is sampled by the
// runtime compositor; only coverage passes through the eye buffer.
render_mode unshaded, blend_mul, cull_disabled, depth_draw_never, depth_test_disabled, fog_disabled, shadows_disabled;
uniform sampler2D menu_texture : filter_linear, repeat_disable;
void vertex() {
    vec3 direction = (VIEW_MATRIX * MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    POSITION = PROJECTION_MATRIX * vec4(direction, 0.0);
    POSITION.z = 0.0;
}
void fragment() {
    float keep = 1.0 - texture(menu_texture, UV).a;
    ALBEDO = vec3(keep);
    ALPHA = keep;
}
